require 'json'
require 'mechanize'
require 'rotp'
require 'fileutils'
require 'tempfile'

# A single cookie jar is shared by all requests in this process. Login and
# requests are serialized because Mechanize and its cookie jar are mutable.
class DeviantArtSession
	class AuthenticationError < StandardError; end
	class GalleryError < StandardError; end
	class UserNotFound < GalleryError; end

	ORIGIN = 'https://www.deviantart.com'
	OEMBED = 'https://backend.deviantart.com/oembed'
	GALLERY = 'https://www.deviantart.com/_puppy/dashared/gallection/contents'
	RENEW_AFTER = 12 * 3600
	RETRY_AFTER = 60
	USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
	COOKIE_JAR_HEADER = '# deviantartrss-session '

	def initialize username, password, totp_key = nil, cookie_jar_path: nil
		@username, @password, @totp_key = username, password, totp_key
		@cookie_jar_path = File.expand_path cookie_jar_path unless cookie_jar_path.to_s.empty?
		@mutex = Mutex.new
	end

	def image_link permalink
		@mutex.synchronize do
			prepare_agent!
			renewed = false
			begin
				data = oembed permalink
			rescue Mechanize::ResponseCodeError => error
				raise unless authentication_configured? && [401, 403].include?(error.response_code.to_i)

				# Invalidated cookies need renewing even when their expiry is in the future.
				@agent = nil
				raise AuthenticationError, 'DeviantArt rejected the renewed session.' if renewed

				login!
				renewed = true
				retry
			end

			url = data['url']
			if authentication_configured? && url&.match?(/,blur_\d+/) && Time.now.to_i - @authenticated_at >= RETRY_AFTER
				# oEmbed can return a blurred image with HTTP 200 for expired sessions.
				# Throttle renewal so paywalled images cannot cause a login storm.
				login!
				url = oembed(permalink)['url']
			end
			url unless url&.match?(/,blur_\d+/)
		end
	end

	def gallery name
		@mutex.synchronize do
			begin
				prepare_agent!
				agent = @agent
			rescue AuthenticationError => error
				warn "Using anonymous gallery access: #{error.message}"
				agent = @public_agent ||= build_agent
			end
			unless @gallery_agent.equal?(agent) && @gallery_csrf_token
				page = agent.get "#{ORIGIN}/"
				token = page.body[/window\.__CSRF_TOKEN__\s*=\s*(['"])([^'"]+)\1/, 2]
				raise GalleryError, 'DeviantArt did not return a gallery session token.' unless page.code == '200' && token

				@gallery_agent, @gallery_csrf_token = agent, token
			end
			query = URI.encode_www_form username: name, type: 'gallery', all_folder: true,
				offset: 0, limit: 60, csrf_token: @gallery_csrf_token
			response = agent.get "#{GALLERY}?#{query}"
			begin
				save_cookie_jar! if agent.equal? @agent
			rescue AuthenticationError => error
				warn error.message
			end
			data = JSON.parse response.body
			unless data.is_a?(Hash) && data['results'].is_a?(Array) && data['gallection'].is_a?(Hash)
				raise GalleryError, 'DeviantArt did not return the expected gallery data.'
			end
			data
		end
	rescue JSON::ParserError
		raise GalleryError, 'DeviantArt returned an invalid gallery response.'
	rescue Mechanize::ResponseCodeError => error
		if [400, 404].include? error.response_code.to_i
			begin
				payload = JSON.parse error.page.body
			rescue JSON::ParserError
				payload = nil
			end
			raise UserNotFound, 'DeviantArt user not found.' if payload.is_a?(Hash) && payload['errorCode'] == 404
		end
		raise
	end

	private

	def prepare_agent!
		if authentication_configured?
			unless @cookie_jar_loaded
				load_cookie_jar!
				@cookie_jar_loaded = true
			end
			login! unless authenticated?
		else
			@agent ||= build_agent
		end
	end

	def authentication_configured?
		!@username.to_s.empty? && !@password.to_s.empty?
	end

	def load_cookie_jar!
		return unless @cookie_jar_path

		File.open @cookie_jar_path, 'r' do |file|
			header = file.readline
			return unless header.start_with? COOKIE_JAR_HEADER

			metadata = JSON.parse header.delete_prefix COOKIE_JAR_HEADER
			return unless metadata.is_a?(Hash) && metadata['username'] == @username

			authenticated_at = metadata['authenticated_at']
			return unless authenticated_at.is_a?(Integer) && authenticated_at.positive? && (Time.now.to_i - authenticated_at).between?(0, RENEW_AFTER - 1)

			agent = build_agent
			agent.cookie_jar.load file, format: :cookiestxt
			@agent = agent
			@authenticated_at = authenticated_at
			@last_attempt = authenticated_at if authenticated?
		end
	rescue Errno::ENOENT
		# The first successful login will create the file.
	rescue JSON::ParserError, EOFError, ArgumentError
		warn 'Ignoring an invalid DeviantArt cookie jar.'
	rescue SystemCallError, IOError
		raise AuthenticationError, 'Cannot read the DeviantArt cookie jar.'
	end

	def save_cookie_jar!
		return unless @cookie_jar_path && @authenticated_at

		directory = File.dirname @cookie_jar_path
		FileUtils.mkdir_p directory
		# Tempfile creates the file with mode 0600; rename preserves that mode and
		# keeps readers from seeing a partially written jar.
		Tempfile.create ['.deviantartrss-cookies-', '.tmp'], directory do |file|
			file.puts COOKIE_JAR_HEADER + JSON.generate(username: @username, authenticated_at: @authenticated_at)
			@agent.cookie_jar.save file, format: :cookiestxt, session: true
			file.flush
			file.fsync
			File.rename file.path, @cookie_jar_path
		end
	rescue SystemCallError, IOError
		raise AuthenticationError, 'Cannot save the DeviantArt cookie jar.'
	end

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
		save_cookie_jar!
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
		save_cookie_jar!
		JSON.parse response.body
	end
end
