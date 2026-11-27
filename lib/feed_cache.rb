require 'nokogiri'
require 'time'
require_relative 'session'

class DeviantArtFeedCache
	class Unavailable < StandardError
		attr_reader :retry_after

		def initialize retry_after
			@retry_after = retry_after
			super 'DeviantArt gallery feeds are temporarily unavailable.'
		end
	end

	class InvalidFeed < StandardError; end

	STALE_AFTER = 86400
	RETRY_AFTER = 300

	def initialize db, session, ttl: 300, clock: -> { Time.now.to_i }
		@db, @session, @ttl, @clock = db, session, ttl, clock
		@mutex = Mutex.new
		@retry_at = @failures = 0
		@db.execute <<~SQL
			create table if not exists feed_cache (
				name text primary key,
				body text not null,
				fetched_at integer not null
			)
		SQL
	end

	def fetch name
		# Coalesce concurrent refreshes so readers of the same feed share one fetch.
		@mutex.synchronize do
			body, fetched_at = @db.get_first_row 'select body, fetched_at from feed_cache where name = ?', name
			now = @clock.call
			return body if fetched_at && now - fetched_at < @ttl
			return stale_or_unavailable(body, fetched_at) if now < @retry_at

			begin
				fresh = @session.rss name
				doc = Nokogiri::XML(fresh) { it.strict.nonet }
				unless doc.at_xpath('/rss/channel') && doc.at_xpath('/rss/channel/description')&.content != 'Error generating RSS.'
					raise InvalidFeed
				end
			rescue Mechanize::ResponseCodeError, DeviantArtSession::AuthenticationError, DeviantArtSession::GalleryError,
				Nokogiri::XML::SyntaxError, InvalidFeed, SocketError, SystemCallError, IOError, Timeout::Error => error
				@failures += 1
				delay = [RETRY_AFTER * 2 ** [@failures - 1, 4].min, 3600].min
				delay = [delay, retry_after(error)].max
				@retry_at = @clock.call + delay
				warn "DeviantArt gallery fetch failed (#{error.class}); backing off for #{delay} seconds."
				return stale_or_unavailable body, fetched_at
			end

			@db.execute 'insert into feed_cache values (?, ?, ?) on conflict(name) do update set body = excluded.body, fetched_at = excluded.fetched_at',
				[name, fresh, @clock.call]
			@retry_at = @failures = 0
			fresh
		end
	end

	private

	def stale_or_unavailable body, fetched_at
		return body if fetched_at && @clock.call - fetched_at <= STALE_AFTER
		raise Unavailable.new [@retry_at - @clock.call, 1].max
	end

	def retry_after error
		return 0 unless error.is_a? Mechanize::ResponseCodeError

		value = error.page['retry-after'].to_s
		return value.to_i if value.match?(/\A\d+\z/)

		[Time.httpdate(value).to_i - @clock.call, 0].max
	rescue ArgumentError
		0
	end
end
