#!/usr/bin/env ruby

require 'net/http'
require 'cgi'

require 'sinatra'
require 'nokogiri'

get '/:name' do
	xml = ->text { Nokogiri::XML text rescue halt 500, "Error processing XML: #{$!.message}"}

	name = params['name']
	url = "https://backend.deviantart.com/rss.xml?type=deviation&q=by%3A#{name}+sort%3Atime+meta%3Aall"
	doc = xml[Net::HTTP.get URI url]
	namespaces = doc.collect_namespaces.transform_keys { it[/^xmlns:(.*)/, 1] }
	at = ->xpath { doc.at_xpath(xpath, namespaces) || halt(500, "Cannot find #{xpath}") }

	description = at['//channel/description']
	halt 204 if description.content == 'Error generating RSS.'
	halt 404, 'No user found' if description.content == "Error generating RSS for by:#{name}"

	name = at['//channel/item[1]/media:credit[1]'].content
	at['//channel/title'].content = name
	icon = at['//channel/item[1]/media:credit[2]'].content
	at['//channel/atom:icon'].content = icon
	at['//channel/link'].content = "https://deviantart.com/#{name}"
	doc.xpath('//channel/atom:link', namespaces).remove

	doc.xpath('//channel/item', namespaces).each do |item|
		next item.remove unless image = item.at_xpath('media:content[@medium="image"]', namespaces)
		next item.remove unless image_url = image['url']
		next item.remove if image_url[/,blur_\d+/]
		next item.remove unless desc = item.at_xpath('description', namespaces)

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

	doc.to_xml
end
