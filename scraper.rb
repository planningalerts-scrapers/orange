#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "date"
require "mechanize"
require "pdf-reader"
require "scraperwiki"
require "stringio"

# Scrapes development applications for Orange City Council (NSW) from two
# WordPress category feeds:
#
# * "New DAs" - weekly posts linking to a PDF listing all applications
#   received during the week
# * "DAs on Exhibition" - posts with application details in the page body
class Scraper
  BASE_URL = "https://www.orange.nsw.gov.au"
  NEW_DAS_URL = "#{BASE_URL}/category/new-das/".freeze
  EXHIBITION_URL = "#{BASE_URL}/category/das-on-exhibition/".freeze

  REF_REGEX = %r{\A(?:DA|CDC|MC)\s*\d+/\d{4}}

  # x positions where the address and description columns of the weekly PDF
  # table start (the reference column starts at ~64)
  PDF_ADDRESS_X = 155
  PDF_DESCRIPTION_X = 341
  # Gap between characters that indicates a word break
  PDF_WORD_GAP = 2.0

  def self.run
    new.run
  end

  def initialize
    @agent = Mechanize.new
    @agent.user_agent_alias = "Mac Firefox"
    return unless ENV.fetch("MORPH_AUSTRALIAN_PROXY", nil)

    # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
    # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
    # the real password.
    puts "Using Australian proxy..."
    @agent.agent.set_proxy(ENV.fetch("MORPH_AUSTRALIAN_PROXY"))
  end

  def run
    count = scrape_received + scrape_exhibition
    puts "Finished - processed #{count} records"
  end

  # Weekly "applications received" posts, each linking to a PDF table
  def scrape_received
    count = 0
    post_urls(NEW_DAS_URL).each do |post_url|
      page = @agent.get(post_url)
      content = page.at(".post-content .content-inner")
      next unless content

      content.search("a[href$='.pdf']").each do |link|
        pdf = @agent.get_file(link["href"])
        parse_received_pdf(pdf).each do |record|
          save(record.merge("info_url" => post_url))
          count += 1
        end
      rescue StandardError => e
        warn "ERROR: Failed to process PDF #{link['href']}: #{e.message}"
      end
    end
    count
  end

  # "DAs on exhibition" posts with h4 (reference - address) and a following
  # paragraph holding the description. A post can list multiple applications.
  def scrape_exhibition
    count = 0
    post_urls(EXHIBITION_URL).each do |post_url|
      page = @agent.get(post_url)
      content = page.at(".post-content .content-inner")
      next unless content

      on_notice_to = parse_on_notice_to(content)
      content.search("h4").each do |heading|
        record = parse_exhibition_heading(heading)
        next unless record

        save(record.merge(
               "info_url" => post_url,
               "on_notice_from" => parse_on_notice_from(page.title, on_notice_to)&.iso8601,
               "on_notice_to" => on_notice_to&.iso8601
             ))
        count += 1
      end
    end
    count
  end

  private

  # Post links, oldest first so that newer posts win when an application
  # appears more than once
  def post_urls(category_url)
    page = @agent.get(category_url)
    page.search("h2.title a, h3.title a").map { |a| a["href"] }.uniq.reverse
  end

  def save(record)
    record = {
      "date_scraped" => Date.today.to_s,
      "on_notice_from" => nil,
      "on_notice_to" => nil,
    }.merge(record)
    puts "Storing #{record['council_reference']} - #{record['address']}"
    ScraperWiki.save_sqlite(["council_reference"], record)
  end

  def clean(text)
    text.to_s.gsub(/\s+/, " ")
        .gsub(/[–—]/, "-")
        .gsub(/(\d)([A-Z][a-z])/, '\1 \2') # repair missing spaces, e.g. "8Daffodil"
        .strip
  end

  def format_address(address)
    address = clean(address)
    address += " NSW" unless address =~ /NSW/i
    address
  end

  # Some references are written "DA 229/2026 (1)", others "DA 229/2026(1)"
  def normalize_reference(reference)
    clean(reference).gsub(/\s+\(/, "(")
  end

  # "DA 237/2026(1) - 89 Sampson Street, Orange"
  def parse_exhibition_heading(heading)
    reference, address = clean(heading.text).split(/\s+-\s+/, 2)
    return unless reference =~ REF_REGEX && address

    {
      "council_reference" => normalize_reference(reference),
      "address" => format_address(address),
      "description" => exhibition_description(heading),
    }
  end

  # The description is the first following paragraph that isn't a document link
  def exhibition_description(heading)
    node = heading
    while (node = node.next_element)
      break if node.name == "h4"
      next unless node.name == "p"
      next if node.at("a")

      text = clean(node.text.delete("\u00a0"))
      return text unless text.empty?
    end
    ""
  end

  # "Submissions must be received by 5 pm on Tuesday, 17 March 2026."
  def parse_on_notice_to(content)
    text = clean(content.text)
    match = text.match(/received by\s+5\s*pm\s+on\s+\w+,?\s+(\d{1,2}\s+\w+\s+\d{4})/i)
    Date.parse(match[1]) if match
  end

  # The exhibition start date is the first date in the post title, which may
  # not include a year, e.g.
  # "Development Application on Exhibition - Tuesday, 18 August - Tuesday, 1 September 2026"
  def parse_on_notice_from(title, on_notice_to)
    match = clean(title.to_s).match(/(\d{1,2})\s+([A-Z][a-z]+)(?:\s+(\d{4}))?/)
    return unless match

    year = match[3]&.to_i || on_notice_to&.year
    return unless year

    date = Date.parse("#{match[1]} #{match[2]} #{year}")
    date = date.prev_year if on_notice_to && date > on_notice_to
    date
  rescue Date::Error
    nil
  end

  # Collects the y positions of the horizontal row separator lines in the
  # PDF table, which are drawn as long thin rectangles
  class RulesReceiver
    attr_reader :rule_ys

    def initialize
      @rule_ys = []
    end

    def append_rectangle(_left, bottom, width, height)
      @rule_ys << bottom if width > 100 && width < 590 && height.abs < 5
    end

    def respond_to_missing?(*)
      true
    end

    def method_missing(*)
      nil
    end
  end

  # The weekly PDF contains a three column table (DA/CDC No, Address,
  # Proposed Development). Lines of text are reassembled from individual
  # characters because the run merging in pdf-reader joins text across column
  # boundaries and drops the occasional space. The horizontal separator lines
  # drawn between table rows are used to group lines of text into rows.
  def parse_received_pdf(pdf)
    rows = []
    PDF::Reader.new(StringIO.new(pdf)).pages.each do |page|
      receiver = RulesReceiver.new
      page.walk(receiver)
      rules = receiver.rule_ys.uniq.sort.reverse
      raise "No table row separators found" if rules.length < 2

      build_pdf_lines(page)
        .group_by { |line| rules.count { |rule_y| rule_y > line[:y] } }
        .each_value do |row_lines|
          row = build_pdf_row(row_lines)
          rows << row if row
        end
    end
    rows
  end

  # Group characters into lines of (y, column, text) with spaces inserted
  # wherever there is a visible gap between characters
  def build_pdf_lines(page)
    chars = page.runs(merge: false).map do |r|
      { x: r.origin.x, y: r.origin.y, width: r.width, text: r.text }
    end
    chars.group_by { |c| [c[:y], column_for(c[:x])] }.map do |(y, column), group|
      text = +""
      cursor = nil
      group.sort_by { |c| c[:x] }.each do |c|
        text << " " if cursor && c[:x] - cursor > PDF_WORD_GAP
        text << c[:text]
        cursor = c[:x] + c[:width]
      end
      { y: y, column: column, text: text.strip }
    end
  end

  def column_for(x_position)
    if x_position >= PDF_DESCRIPTION_X
      :description
    elsif x_position >= PDF_ADDRESS_X
      :address
    else
      :reference
    end
  end

  def build_pdf_row(lines)
    reference = join_column(lines, :reference)
    return unless reference =~ REF_REGEX

    {
      "council_reference" => normalize_reference(reference),
      "address" => format_address(join_column(lines, :address)),
      "description" => clean(join_column(lines, :description)),
    }
  end

  def join_column(lines, column)
    lines.select { |l| l[:column] == column }
         .sort_by { |l| -l[:y] }
         .map { |l| l[:text] }
         .join(" ")
  end
end

Scraper.run if __FILE__ == $PROGRAM_NAME
