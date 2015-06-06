require 'rest-client'
require 'json'
require 'date'
require 'csv'
require 'yaml'
require 'net/smtp'

CONFIG = YAML.load_file('./secrets/secrets.yml')

date = Date.today - CONFIG["num_days"].to_i

FILE_DIR = './csv'
Dir.mkdir(FILE_DIR) unless File.exists?(FILE_DIR)

file_date = date.strftime("%Y%m")
csv_file_name = "reviews_#{CONFIG["package_name"]}_#{file_date}.csv"

system "BOTO_PATH=./secrets/.boto gsutil/gsutil -m cp -r gs://#{CONFIG["app_repo"]}/reviews/#{csv_file_name} #{FILE_DIR}"

class Email
  def self.send(message)
  		msg = "Subject: Google Play reviews #{Date.today}\n\n#{message}"
    	smtp = Net::SMTP.new CONFIG["smtp_address"], CONFIG["smtp_port"].to_i
    	smtp.enable_starttls
    	smtp.start(CONFIG["smtp_address"], CONFIG["smtp_user"], CONFIG["smtp_pass"], :login) do
      		smtp.send_message(msg, CONFIG["smtp_user"],CONFIG["email_send_to"])
	    end
  end
end


class Slack
  def self.notify(message)
    RestClient.post CONFIG["slack_url"], {
      payload:
      { text: message }.to_json
    },
    content_type: :json,
    accept: :json
  end
end

class Review
  def self.collection
    @collection ||= []
  end

  def self.send_reviews_from_date(date, send_slack, send_email)
    message = collection.select do |r|
      r.submitted_at > date && (r.title || r.text)
    end.sort_by do |r|
      r.submitted_at
    end.map do |r|
      r.build_message
    end.join("\n")


    if message != ""
    	Email.send(message) if send_email
      	Slack.notify(message) if send_slack
    else
      print "No new reviews\n"
    end
  end

  attr_accessor :app_package, :text, :title, :submitted_at, :original_subitted_at, :rate, :device, :url, :version, :edited

  def initialize data = {}
  	@app_package = data[:app_package] ? data[:app_package].to_s.encode("utf-8") : nil
    @text = data[:text] ? data[:text].to_s.encode("utf-8") : nil
    @title = data[:title] ? "*#{data[:title].to_s.encode("utf-8")}*\n" : nil

    @submitted_at = DateTime.parse(data[:submitted_at].encode("utf-8"))
    @original_subitted_at = DateTime.parse(data[:original_subitted_at].encode("utf-8"))

    @rate = data[:rate].encode("utf-8").to_i
    @device = data[:device] ? data[:device].to_s.encode("utf-8") : nil
    @url = data[:url].to_s.encode("utf-8")
    @version = data[:version].to_s.encode("utf-8")
    @edited = data[:edited]
  end

  def build_message
    date = if edited
             "subdate: #{original_subitted_at.strftime("%d.%m.%Y at %I:%M%p")}, edited at: #{submitted_at.strftime("%d.%m.%Y at %I:%M%p")}"
           else
             "subdate: #{submitted_at.strftime("%d.%m.%Y at %I:%M%p")}"
           end

    stars = rate.times.map{"★"}.join + (5 - rate).times.map{"☆"}.join

    [
      "\n\n#{app_package} ",
      "#{stars}",
      "Version: #{version} | #{date}",
      "#{[title, text].join(" ")}",
      "<#{url}|View in Google play>"
    ].join("\n")
  end
end

Dir["#{FILE_DIR}/*"].each do |file_name|
  next if File.directory? file_name
   
	CSV.foreach(file_name, encoding: 'bom|utf-16le', headers: true) do |row|
	  # If there is no reply - push this review
	  if row[11].nil?
	    Review.collection << Review.new({
	      app_package: row[0],
	      text: row[10],
	      title: row[9],
	      submitted_at: row[6],
	      edited: (row[4] != row[6]),
	      original_subitted_at: row[4],
	      rate: row[8],
	      device: row[3],
	      url: row[14],
	      version: row[1],
    	})
 	 end
	end
end

send_slack = (CONFIG["slack_url"].length > 0)
send_email = (CONFIG["smtp_address"].length > 0)

Review.send_reviews_from_date(date, send_slack, send_email)
