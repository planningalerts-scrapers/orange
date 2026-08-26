Orange City Council
===================

Orange City Council publishes development applications as WordPress posts in
two categories, both scraped here:

* [New DAs](https://www.orange.nsw.gov.au/category/new-das/) - weekly posts,
  each linking to a PDF listing every application received during the week.
  The PDF table is parsed using character positions and the drawn row
  separator lines.
* [DAs on Exhibition](https://www.orange.nsw.gov.au/category/das-on-exhibition/) -
  posts with application details in the page body, including the exhibition
  period which is stored as `on_notice_from` / `on_notice_to`.

Applications appearing in both feeds are stored once, keyed on
`council_reference` (posts are processed oldest first so the most recent
information wins).

This is a scraper that runs on [Morph](https://morph.io). To get started [see the documentation](https://morph.io/documentation)

Add any issues to https://github.com/planningalerts-scrapers/issues/issues

Set `MORPH_AUSTRALIAN_PROXY` to an Australian proxy, preferably one that rotates its IP address

## Expected Output

    Storing DA 205/2026(1) - Lot 17 DP 574798 - 6 Beasley Street, Orange NSW
    Storing DA 206/2026(1) - Lot 14 DP 1070456 - 10 Brooklands Drive, Orange NSW
    ...
    Storing DA 237/2026(1) - 89 Sampson Street, Orange NSW
    Finished - processed 77 records

Expected runtime: ~ 30 seconds

## To run the scraper

    bundle exec ruby scraper.rb

## To run style and coding checks

    bundle exec rubocop

## To check for security updates

    gem install bundler-audit
    bundle-audit
