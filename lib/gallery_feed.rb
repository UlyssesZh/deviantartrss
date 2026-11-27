require 'nokogiri'
require 'time'
require_relative 'session'

# Produce RSS from the same JSON listing used by DeviantArt's gallery pages.
# No request to backend.deviantart.com/rss.xml is needed.
class DeviantArtGalleryFeed
	def initialize session
		@session = session
	end

	def rss name
		data = @session.gallery name
		owner = data.dig('gallection', 'owner')
		unless owner.is_a?(Hash) && owner['username'].is_a?(String) && owner['usericon'].is_a?(String)
			raise DeviantArtSession::GalleryError, 'DeviantArt gallery owner information is missing.'
		end

		Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
			xml.rss 'version' => '2.0', 'xmlns:media' => 'http://search.yahoo.com/mrss/', 'xmlns:atom' => 'http://www.w3.org/2005/Atom' do
				xml.channel do
					xml.title owner['username']
					xml.link "https://www.deviantart.com/#{owner['username']}"
					xml.description "Gallery of #{owner['username']}"
					xml['atom'].icon owner['usericon']
					data['results'].first(60).each do |deviation|
						next unless deviation['type'] == 'image'
						next if deviation['isDeleted'] || deviation['isBlocked'] || deviation['isVideo'] || deviation['isJournal']
						next unless image = image_url(deviation['media'])
						unless deviation['url'].is_a?(String) && deviation['title'].is_a?(String) && deviation['publishedTime'].is_a?(String)
							raise DeviantArtSession::GalleryError, 'DeviantArt artwork information is missing.'
						end
						xml.item do
							xml.title deviation['title']
							xml.link deviation['url']
							xml.guid deviation['url'], 'isPermaLink' => 'true'
							xml.pubDate Time.parse(deviation['publishedTime']).rfc2822
							xml.description description(deviation['url'], image)
							xml['media'].credit owner['username']
							xml['media'].credit owner['usericon']
							xml['media'].content 'medium' => 'image', 'url' => image
							xml['media'].thumbnail 'url' => image
						end
					end
				end
			end
		end.to_xml
	rescue DeviantArtSession::UserNotFound
		Nokogiri::XML::Builder.new do |xml|
			xml.rss(version: '2.0') { xml.channel { xml.description "Error generating RSS for by:#{name}" } }
		end.to_xml
	rescue ArgumentError
		raise DeviantArtSession::GalleryError, 'DeviantArt returned invalid artwork metadata.'
	end

	private

	def image_url media
		return unless media.is_a?(Hash) && media['baseUri'].is_a?(String)

		formats = media.fetch('types', [])
		format = formats.find { it['t'] == 'fullview' } || formats.find { it['t'] == 'preview' }
		return unless format

		url = media['baseUri'].dup
		tokens = media.fetch('token', [])
		if tokens.size <= 1 && format['c']
			url += format['c'].gsub '<prettyName>', media.fetch('prettyName', '')
		end
		url += "?#{URI.encode_www_form(token: tokens.last)}" if tokens.last
		url
	end

	def description permalink, image
		Nokogiri::XML::Builder.new do |xml|
			xml.body do
				xml.div { xml.img src: image }
				xml.p { xml.a 'View artwork on DeviantArt', href: permalink }
			end
		end.doc.root.children.to_xml
	end
end
