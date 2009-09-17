require 'rubygems'
require 'uuid'
require 'net/http'
require 'net/https'
require 'rexml/document'
require 'digest/sha1'
require 'logger'

class FetionException < Exception
end

class Fetion
  attr_accessor :mobile_no, :password
  attr_reader :uri

  FETION_URL = 'http://221.130.44.194/ht/sd.aspx'
  FETION_LOGIN_URL = 'https://nav.fetion.com.cn/ssiportal/SSIAppSignIn.aspx'
  FETION_CONFIG_URL = 'http://nav.fetion.com.cn/nav/getsystemconfig.aspx'
  FETION_SIPP = 'SIPP'
  GUID = UUID.new.generate

  def initialize
    @next_call = 0
    @seq = 0
    @buddies = []
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
  end
  
  def logger_level=(level)
    @logger.level = level
  end

  def send_sms_to_self(content)
    login
    register
    send_sms(@uri, content)
  end

  def login
    @logger.info "fetion login"
    uri = URI.parse(FETION_LOGIN_URL + "?mobileno=#{@mobile_no}&pwd=#{@password}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    headers = {'Content-Type' => 'application/oct-stream', 'Pragma' => "xz4BBcV#{GUID}", 'User-Agent' => 'IIC2.0/PC 3.2.0540'}
    response = http.request_get(uri.request_uri, headers)

    raise FetionException.new('Fetion Error: Login failed.') unless response.is_a? Net::HTTPSuccess
    raise FetionException.new('Fetion Error: No ssic found in cookie.') unless response['set-cookie'] =~ /ssic=(.*);/

    @ssic = $1
    doc = REXML::Document.new(response.body)
    results = doc.root
    @status_code = results.attributes["status-code"]
    user = results.children.first
    @user_status = user.attributes['user-status']
    @uri = user.attributes['uri']
    @mobile_no = user.attributes['mobile-no']
    @user_id = user.attributes['user-id']
    if @uri =~ /sip:(\d+)@(.+);/
      @sid = $1
      @domain = $2
    end
    @logger.debug "ssic: " + @ssic
    @logger.debug "status_code: " + @status_code
    @logger.debug "user_status: " + @user_status
    @logger.debug "uri: " + @uri
    @logger.debug "mobile_no: " + @mobile_no
    @logger.debug "user_id: " + @user_id
    @logger.debug "sid: " + @sid
    @logger.debug "domain: " + @domain
    @logger.info "fetion login success"
  end

  def register
    @logger.info "fetion http register"
    arg = '<args><device type="PC" version="44" client-version="3.2.0540" /><caps value="simple-im;im-session;temp-group;personal-group" /><events value="contact;permission;system-message;personal-group" /><user-info attributes="all" /><presence><basic value="400" desc="" /></presence></args>'

    call = next_call
    curl_exec(next_url, @ssic, FETION_SIPP)

    msg = sip_create("R fetion.com.cn SIP-C/2.0", {'F' => @sid, 'I' => call, 'Q' => '1 R'}, arg) + FETION_SIPP
    curl_exec(next_url('i'), @ssic, msg)

    response = curl_exec(next_url, @ssic, FETION_SIPP)
    raise FetionException.new("Fetion Error: no nonce found") unless response.body =~ /nonce="(\w+)"/
      
    @nonce = $1
    @salt =  "777A6D03"
    @cnonce = calc_cnonce
    @response = calc_response

    @logger.debug "nonce: #{@nonce}"
    @logger.debug "salt: #{@salt}"
    @logger.debug "cnonce: #{@cnonce}"
    @logger.debug "response: #{@response}"

    msg = sip_create('R fetion.com.cn SIP-C/2.0', {'F' => @sid, 'I' => call, 'Q' => '2 R', 'A' => "Digest algorithm=\"SHA1-sess\",response=\"#{@response}\",cnonce=\"#{@cnonce}\",salt=\"#{@salt}\""}, arg) + FETION_SIPP
    curl_exec(next_url, @ssic, msg)
    response = curl_exec(next_url, @ssic, FETION_SIPP)

    @logger.info "fetion http register success"
    response.is_a? Net::HTTPSuccess
  end

  def get_buddy_list
    @logger.info "fetion get buddy list"
    arg = '<args><contacts><buddy-lists /><buddies attributes="all" /><mobile-buddies attributes="all" /><chat-friends /><blacklist /></contacts></args>'
    msg = sip_create('S fetion.com.cn SIP-C/2.0', {'F' => @sid, 'I' => next_call, 'Q' => '1 S', 'N' => 'GetContactList'}, arg) + FETION_SIPP
    curl_exec(next_url, @ssic, msg)
    response = curl_exec(next_url, @ssic, FETION_SIPP)
    raise FetionException.new("Fetion Error: No buddy list found") unless response.body =~ /.*?\r\n\r\n(.*)#{FETION_SIPP}\s*$/i

    doc = REXML::Document.new($1)
    doc.elements.each("//buddies/buddy") do |buddy|
      @buddies << buddy.attributes
    end
    doc.elements.each("//mobile-buddies/mobile-buddy") do |buddy|
      @buddies << buddy.attributes
    end
    @logger.info @buddies.inspect
    @logger.info "fetion get buddy list success"
  end

  def send_sms(to, content)
    @logger.info "fetion send sms to #{to}"
    msg = sip_create('M fetion.com.cn SIP-C/2.0', {'F' => @sid, 'I' => next_call, 'Q' => '1 M', 'T' => to, 'N' => 'SendSMS'}, content) + FETION_SIPP
    curl_exec(next_url, @ssic, msg)

    response = curl_exec(next_url, @ssic, FETION_SIPP)
    @logger.info "fetion send sms to #{to} success"
    response.is_a? Net::HTTPSuccess
  end

  def curl_exec(url, ssic, body)
    @logger.debug "fetion curl exec"
    @logger.debug "url: #{url}"
    @logger.debug "ssic: #{ssic}"
    @logger.debug "body: #{body}"
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    headers = {'Content-Type' => 'application/oct-stream', 'Pragma' => "xz4BBcV#{GUID}", 'User-Agent' => 'IIC2.0/PC 3.2.0540', 'Cookie' => "ssic=#{@ssic}"}
    response = http.request_post(uri.request_uri, body, headers)

    @logger.debug "response: #{response.inspect}"
    @logger.debug "response body: #{response.body}"
    @logger.debug "fetion curl exec complete"
    response
  end

  def sip_create(invite, fields, arg)
    sip = invite + "\r\n"
    fields.each {|k, v| sip += "#{k}: #{v}\r\n"}
    sip += "L: #{arg.size}\r\n\r\n#{arg}"
    @logger.debug "sip message: #{sip}"
    sip
  end

  def calc_response
    str = [hash_password[8..-1]].pack("H*")
    key = Digest::SHA1.digest("#{@sid}:#{@domain}:#{str}")

    h1 = Digest::MD5.hexdigest("#{key}:#{@nonce}:#{@cnonce}").upcase
    h2 = Digest::MD5.hexdigest("REGISTER:#{@sid}").upcase
    
    Digest::MD5.hexdigest("#{h1}:#{@nonce}:#{h2}").upcase
  end

  def calc_cnonce
    Digest::MD5.hexdigest(UUID.new.generate).upcase
  end

  def hash_password
    salt = "#{0x77.chr}#{0x7A.chr}#{0x6D.chr}#{0x03.chr}"
    src = salt + Digest::SHA1.digest(@password)
    '777A6D03' + Digest::SHA1.hexdigest(src).upcase
  end

  def next_url(t = 's')
    @seq += 1
    FETION_URL + "?t=#{t}&i=#{@seq}"
  end

  def next_call
    @next_call += 1
    @next_call
  end
end

