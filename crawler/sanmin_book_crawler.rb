require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'
require 'isbn'

require 'thread'
require 'thwait'

# 書量多到最好來個 redis 支援

class SanminBookCrawler

  SLEEP_INTERVAL = 0.3

  ATTR_HASH = {
    "ISBN13" => :isbn,
    "ISBN10" => :isbn,
    "ISBN" => :isbn,
    "出版社" => :publisher,
    "作者" => :author,
  }

  def initialize
    @index_url = "http://www.m.sanmin.com.tw"
    # @start_urls = [
    #   "http://www.m.sanmin.com.tw/Product/Scheme1",
    #   "http://www.m.sanmin.com.tw/Product/SchemeChina1"
    # ]

    # @start_categories = [
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=0",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=1",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=2",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=3",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=4",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=5",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=6",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=7",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=8",
    #   "http://www.m.sanmin.com.tw/Product/Scheme1/?id=9",
    # ]

    @start_categories = [
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0017",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0003",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0016",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0007",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0010",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0006",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0012",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0002",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0014",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0013",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0001",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0015",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0009",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0011",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0004",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0008",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0005",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0018",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0019",
      "http://www.m.sanmin.com.tw/Promote/OriginalText2/?id=OT0020"
    ]
  end

  def books
    @books = []

    @start_categories.each do |category_url|
      sleep SLEEP_INTERVAL

      r = curl_get category_url
      doc = Nokogiri::HTML(r)

      # category_urls = doc.xpath('//a/@href').map(&:to_s).uniq.select{|href| href.match(/\/Product\/Scheme/) && href.match(/id=/) }.map{|href| URI.join(@index_url, href).to_s}.uniq - @start_categories

      book_count = nil; page_count = nil;
      doc.css('.txtTotalInfo').text.match(/共(?<book_count>\d+)筆商品，目前 \d\/(?<page_count>\d+)頁/) do |m|
        page_count = m[:page_count].to_i
        book_count = m[:book_count].to_i
      end

      if (status_code = check_page_status(doc)) == 1
        sleep SLEEP_INTERVAL
        redo
      elsif status_code == -1
        next
      end

      # 認真了！開始抓頁面資料
      parse_page(doc)
      print "1\n"

      (2..page_count).each do |i|
        page_url = "#{category_url}&index=#{i}"
        sleep SLEEP_INTERVAL
        r = curl_get(page_url)
        doc = Nokogiri::HTML(r)

        if (status_code = check_page_status(doc)) == 1
          print "oh no"
          sleep SLEEP_INTERVAL
          redo
        elsif status_code == -1
          break
        end

        parse_page(doc)
        print "#{i}\n"
      end if page_count && page_count > 1
    end # end each start_category

    @books
  end

  def parse_page doc
    names = doc.css('.ProdListTd .blue16 a').map{ |d| d.text.strip }
    green_spans = doc.css('span.green13')

    authors = (0...green_spans.count).select{|i| i%2 == 0}.map{|i| green_spans[i].text[0..-2] }
    publishers = (0...green_spans.count).select{|i| i%2 == 1}.map{|i| green_spans[i].text[0..-2] }
    image_blocks = doc.css('.ProdList .SanminProdImg')
    external_image_urls = image_blocks.xpath('a/img/@original').map{|src| URI.join(@index_url, src.to_s).to_s }
    urls = image_blocks.xpath('a/@href').map{|href| URI.join(@index_url, href.to_s).to_s }

    prices = doc.xpath('//tr[@class="ProdList"]/td[@class="ProdListTd"]/table').map{|table| table.text.match(/(?<=定價：)[\d,]+/).to_s.gsub(/[^\d]/, '').to_i }

    book_count = names.count

    threads = []
    (0...book_count).each { |i|
      threads << Thread.new do
        book = {
          name: names[i],
          author: authors[i],
          publisher: publishers[i],
          external_image_url: external_image_urls[i],
          url: urls[i],
          price: prices[i]
        }
        book.each {|k, v| book[k] = nil if v && v.is_a?(String) && v.empty?}
        @books << parse_detail(book)
      end
    }
    ThreadsWait.all_waits(*threads)
  end

  def check_page_status doc
    names = doc.xpath('//td[@class="blue16"]')
    # 沒書啊
    if names.count == 0
      # Frequency Limitaion Zzz
      if doc.text.include?("系統提醒您，切換頁面的速度請勿過於頻繁。")
        return 1
      else
        return -1
      end
    end
    return 0
  end

  def parse_detail book
    r = curl_get book[:url]
    doc = Nokogiri::HTML(r)

    book[:name] ||= doc.css('.ProdName').text

    doc.css('.ProdInfo li').map{|li| li.text.strip}.each{|attr_data|
      key = attr_data.rpartition('：')[0]
      book[ATTR_HASH[key]] = attr_data.rpartition('：')[-1] if ATTR_HASH[key]
    }
    book[:isbn] = isbn_to_13(book[:isbn]) if book[:isbn]
    book[:external_image_url] ||= doc.xpath('//img[@class="SanminProdImg"]/@original').to_s

    return book
  end

  # 恩...你知道我也不是很想這樣做，反正他就這樣動了
  # 我也不知道要怎麼樣了，好歹他也是能跑了，就這樣吧
  def curl_get url
    %x(curl -s '#{url}' -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8' -H 'Connection: keep-alive' -H 'Accept-Encoding: gzip, deflate, sdch' -H 'Accept-Language: en-US,en;q=0.8,zh-TW;q=0.6,zh;q=0.4,ja;q=0.2' -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/43.0.2357.134 Safari/537.36' --compressed)
  end

  def isbn_to_13 isbn
    case isbn.length
    when 13
      return ISBN.thirteen isbn
    when 10
      return ISBN.thirteen isbn
    when 12
      return "#{isbn}#{isbn_checksum(isbn)}"
    when 9
      return ISBN.thirteen("#{isbn}#{isbn_checksum(isbn)}")
    end
  end

  def isbn_checksum(isbn)
    isbn.gsub!(/[^(\d|X)]/, '')
    c = 0
    if isbn.length <= 10
      10.downto(2) {|i| c += isbn[10-i].to_i * i}
      c %= 11
      c = 11 - c
      c ='X' if c == 10
      return c
    elsif isbn.length <= 13
      (1..11).step(2) {|i| c += isbn[i].to_i}
      c *= 3
      (0..11).step(2) {|i| c += isbn[i].to_i}
      c = (220-c) % 10
      return c
    end
  end
end

cc = SanminBookCrawler.new
File.write('sanmin_books.json', JSON.pretty_generate(cc.books))
