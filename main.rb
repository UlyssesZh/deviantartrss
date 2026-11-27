#!/usr/bin/env ruby

require 'net/http'
require 'cgi'
require 'fileutils'
require 'json'

require 'sinatra'
require 'nokogiri'
require 'sqlite3'

require_relative 'lib/session'
require_relative 'lib/feed_cache'
require_relative 'lib/gallery_feed'

cookie_jar_path = File.expand_path ENV.fetch 'DEVIANTARTRSS_COOKIE_JAR', 'cookies.txt'
DEVIANTART = DeviantArtSession.new(ENV['DEVIANTARTRSS_USERNAME'], ENV['DEVIANTARTRSS_PASSWORD'], ENV['DEVIANTARTRSS_TOTP_KEY'], cookie_jar_path:)

db_path = File.expand_path ENV.fetch 'DEVIANTARTRSS_DB', 'data.db'
FileUtils.mkdir_p File.dirname db_path
DB = SQLite3::Database.new db_path
DB.execute <<-SQL
	create table if not exists image_link_cache (
		permalink text primary key,
		image_link text,
		created_at integer
	);
SQL

FEEDS = DeviantArtFeedCache.new DB, DeviantArtGalleryFeed.new(DEVIANTART)

IMAGE_LINK_CACHE_EXPIRE = (ENV.fetch 'DEVIANTARTRSS_IMAGE_LINK_CACHE_EXPIRE', 15*86400).to_i
def image_link permalink
	now = Time.now.to_i
	image_link, created_at = DB.get_first_row 'select image_link, created_at from image_link_cache where permalink = ?', permalink
	image_link = nil if created_at && now - created_at >= IMAGE_LINK_CACHE_EXPIRE
	return image_link if image_link
	begin
		image_link = DEVIANTART.image_link permalink
	rescue DeviantArtSession::AuthenticationError => e
		$stderr.puts e.message
		halt 503, 'DeviantArt authentication is unavailable'
	rescue => e
		$stderr.puts "DeviantArt image request failed (#{e.class})"
		return
	end
	image_link = nil if image_link&.[] /,blur_\d+/
	DB.execute 'delete from image_link_cache where permalink = ?', permalink if created_at
	DB.execute 'insert into image_link_cache values (?, ?, ?)', [permalink, image_link, now]
	image_link
end

def proxy_image name, art
	image_url = image_link "https://www.deviantart.com/#{name}/art/#{art}"
	return halt 204, 'Current user cannot view this image' unless image_url
	redirect image_url, 307
end

get '/:name' do
	return proxy_image params['name'], params['art'] if params['art']

	xml = ->text { Nokogiri::XML text rescue halt 500, "Error processing XML: #{$!.message}"}

	name = params['name']
	begin
		feed = FEEDS.fetch name
	rescue DeviantArtFeedCache::Unavailable => error
		headers 'Retry-After' => error.retry_after.to_s
		halt 503, error.message
	end
	doc = xml[feed]
	namespaces = doc.collect_namespaces.transform_keys { it[/^xmlns:(.*)/, 1] }
	at = ->xpath { doc.at_xpath(xpath, namespaces) || halt(500, "Cannot find #{xpath}") }

	description = at['//channel/description']
	halt 204 if description.content == 'Error generating RSS.'
	halt 404, 'No user found' if description.content == "Error generating RSS for by:#{name}"

	name = doc.at_xpath('//channel/item[1]/media:credit[1]', namespaces)&.content || at['//channel/title'].content
	at['//channel/title'].content = name

	icon_url = doc.at_xpath('//channel/item[1]/media:credit[2]', namespaces)&.content || at['//channel/atom:icon'].content
	icon_url = icon_url.sub '/avatars/', '/avatars-big/'
	icon = at['//channel/atom:icon']
	icon.content = icon_url
	site_image = Nokogiri::XML::Node.new 'image', doc
	site_image.add_child Nokogiri::XML::Node.new('title', doc).tap { it.content = name }
	site_image.add_child Nokogiri::XML::Node.new('url', doc).tap { it.content = icon_url }
	site_image.add_child Nokogiri::XML::Node.new('link', doc).tap { it.content = "https://deviantart.com/#{name}" }
	site_image.add_child Nokogiri::XML::Node.new('width', doc).tap { it.content = '50' }
	site_image.add_child Nokogiri::XML::Node.new('height', doc).tap { it.content = '50' }
	icon.add_next_sibling site_image

	at['//channel/link'].content = "https://deviantart.com/#{name}"
	doc.xpath('//channel/atom:link', namespaces).remove

	doc.xpath('//channel/item', namespaces).each do |item|
		next item.remove unless image = item.at_xpath('media:content[@medium="image"]', namespaces)
		next item.remove unless image_url = image['url']
		next item.remove unless desc = item.at_xpath('description', namespaces)

		# starting from Nov 2025, adult contents are blurred as well
		if image_url[/,blur_\d+/]
			# deviants meeting this condition seem to be behind paywall
			next item.remove if item.xpath('media:thumbnail', namespaces).map { it['url'][/,blur_(\d+)/, 1].to_i }.min == 30
		end

		permalink = item.at_xpath('link', namespaces).content
		image_url = "#{request.base_url}/#{params['name']}?art=#{permalink[%r{/([^/]+)$}, 1]}"
		image['url'] = image_url

		item.xpath('media:thumbnail', namespaces).remove
		image.remove_attribute 'medium'
		image.name = 'thumbnail'

		item.xpath('media:description', namespaces).remove

		content_doc = xml["<body>#{CGI.unescapeHTML desc.content}</body>"]
		next unless div = content_doc.at_xpath('(//div[img])[last()]')
		div.at_xpath('img')['src'] = image_url
		div.remove
		content_doc.root.children.first.add_previous_sibling div
		desc.content = content_doc.root.children.map(&:to_xml).join
	end

	content_type 'text/xml;charset=utf-8'
	doc.to_xml
end
