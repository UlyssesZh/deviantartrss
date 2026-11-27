require 'json'
require 'mechanize'
require 'rotp'

# A single cookie jar is shared by all requests in this process. Login and
# requests are serialized because Mechanize and its cookie jar are mutable.
class DeviantArtSession
	class AuthenticationError < StandardError; end

	ORIGIN = 'https://www.deviantart.com'
	OEMBED = 'https://backend.deviantart.com/oembed'
	RENEW_AFTER = 12 * 3600
	RETRY_AFTER = 60
	USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

	def initialize username, password, totp_key = nil
		@username, @password, @totp_key = username, password, totp_key
		@mutex = Mutex.new
	end

	def image_link permalink
		@mutex.synchronize do
			login! unless authenticated?
			renewed = false
			begin
				data = oembed permalink
			rescue Mechanize::ResponseCodeError => error
				raise unless [401, 403].include?(error.response_code.to_i)

				# Invalidated cookies need renewing even when their expiry is in the future.
				@agent = nil
				raise AuthenticationError, 'DeviantArt rejected the renewed session.' if renewed

				login!
				renewed = true
				retry
			end

			url = data['url']
			if url&.match?(/,blur_\d+/) && Time.now.to_i - @authenticated_at >= RETRY_AFTER
				# oEmbed can return a blurred image with HTTP 200 for expired sessions.
				# Throttle renewal so paywalled images cannot cause a login storm.
				login!
				url = oembed(permalink)['url']
			end
			url unless url&.match?(/,blur_\d+/)
		end
	end

	private

	def build_agent
		Mechanize.new do |agent|
			agent.user_agent = USER_AGENT
			agent.open_timeout = 15
			agent.read_timeout = 30
			agent.max_history = 0
			agent.request_headers = { 'Accept-Language' => 'en-US,en;q=0.9' }
		end
	end

	def authenticated?
		return false unless @agent && @authenticated_at && Time.now.to_i - @authenticated_at < RENEW_AFTER

		names = @agent.cookie_jar.cookies(URI OEMBED).map &:name
		%w[auth auth_secure userinfo].all? { names.include? it }
	end

	def login!
		if @username.to_s.empty? || @password.to_s.empty?
			raise AuthenticationError, 'Username and password are not provided.'
		end
		if @last_attempt && Time.now.to_i - @last_attempt < RETRY_AFTER
			raise AuthenticationError, 'Please wait one minute before retrying DeviantArt login.'
		end
		@last_attempt = Time.now.to_i
		agent = build_agent
		page = agent.get "#{ORIGIN}/users/login"
		page = submit agent, page, 'username', @username
		page = submit agent, page, 'password', @password
		if page.is_a?(Mechanize::Page) && page.at('input[name="verification_code"]')
			if @totp_key.to_s.empty?
				raise AuthenticationError, 'This account requires a TOTP key.'
			end
			code = ROTP::TOTP.new(@totp_key.gsub /\s+/, '').now
			page = submit agent, page, 'verification_code', code
		end
		names = agent.cookie_jar.cookies(URI OEMBED).map &:name
		unless %w[auth auth_secure userinfo].all? { names.include? it }
			raise AuthenticationError, 'DeviantArt login did not issue authentication cookies. Check the credentials or any account challenge.'
		end
		@agent = agent
		@authenticated_at = Time.now.to_i
		@username
	rescue AuthenticationError
		raise
	rescue StandardError
		# Upstream exceptions may contain form data. Never log credentials or TOTP codes.
		raise AuthenticationError, 'DeviantArt login failed. The login service may be unavailable or require a browser challenge.'
	end

	def submit agent, page, field, value
		form = page.forms.find { it.field_with name: field } if page.is_a? Mechanize::Page
		unless form && page.code == '200'
			raise AuthenticationError, 'DeviantArt did not return the expected login form. A browser challenge may be required.'
		end
		action = URI.join page.uri.to_s, form.action
		unless action.scheme == 'https' && action.host == 'www.deviantart.com' && action.port == 443
			raise AuthenticationError, 'DeviantArt returned an unexpected login destination.'
		end
		form[field] = value
		form.checkbox_with(name: 'remember')&.check
		agent.submit form, nil, 'Origin' => ORIGIN
	end

	def oembed permalink
		response = @agent.get "#{OEMBED}?#{URI.encode_www_form(url: permalink)}"
		JSON.parse response.body
	end
end
