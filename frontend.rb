#!/usr/bin/env ruby
# encoding: utf-8

require 'sinatra'
require 'grit'
require 'yaml'
require 'pp'
require 'socket'
require 'timeout'
require 'logger'


def md5sum fn
    md5 = `md5sum #{fn}`
    fail if $?.exitstatus != 0
    md5
end

YAML::ENGINE.yamler='syck'
ROOT= File.dirname(File.expand_path __FILE__)
CONFIG_FILE= File.join ROOT, "config.yaml"
$CONFIG=YAML.load File.read(CONFIG_FILE)
config_md5 = md5sum CONFIG_FILE
pp $CONFIG
puts "fffffffffffffffffffffffffffffffffffffff"
REQUEST=File.join ROOT, "request_mgmt", "request"

LOGGER = Logger.new STDERR

set :public_folder, File.dirname(__FILE__) + '/views'
set :bind, $CONFIG[:bind] || '0.0.0.0'
set :port, $CONFIG[:port] || 4567

$formats = {
    /(\[ *PASS *\])/ => '<span class="line-ok">\1</span>',
    /(\[ *! *PASS *! *\])/ => '<span class="line-warning">\1</span>',
    /(\[ *FAIL *\])/ => '<span class="line-warning">\1</span>',
    /(\[ *! *FAIL *! *\])/ => '<span class="line-error">\1</span>',
    /(\[ *!? *BROKEN *!? *\])/ => '<span class="line-error">\1</span>',
}

helpers do
    def h(text)
        Rack::Utils.escape_html(text)
    end
    def tr(text, len)
        len = 3 if len<3
        return "nil" unless text
        return text if text.length < len
        text[0..len-3]+"..."
    end
    def ol(line)
        t = h line.chomp
        $formats.each do |p, s|
            return t.gsub(p, s) if t =~ p
        end
        t
    end
    def format(section, repo, tid, result)
        text = ""
        formatter_output = ""

        cwd = Dir.getwd
        repo_abspath = $CONFIG[:repo_abspath]
        result_abspath = $CONFIG[:result_abspath]
        #Dir.chdir File.join(repo_abspath, repo)

        formatter = ""
        if File.executable_real? "formatter.py"
            formatter = "./formatter.py"
        elsif File.executable_real? "labcodes/formatter.py"
            formatter = "./labcodes/formatter.py"
        end
        if formatter != ""
            command = formatter + " " + section + " " + result_abspath + " " + repo + " " + tid
            result.each do |line|
                text << line + "\n"
            end
            begin
                pipe = IO.popen("#{command}", mode="r+")
            rescue Exception => e
                return text
            end
            pipe.write text
            pipe.close_write
            formatter_output = pipe.read
            Process.waitpid2(pipe.pid)
        else
            result.each do |line|
                formatter_output << ol(line) + "<br>"
            end
        end
        Dir.chdir cwd
        return formatter_output
    end
end

class ReportCache
    @@cache = Hash.new

    class << self

        def check_repo(repo)
            return false unless repo =~ /[a-zA-A_]+/
            $CONFIG[:repos].any? {|e| e[:name] == repo }
        end

        def [](repo)
            @@cache[repo]
        end

        def check_and_update(repo)
           # return nil unless check_repo repo
            unless File.directory? File.join($CONFIG[:result_abspath], repo)
                @@cache.delete repo
                return nil
            end

            @@cache[repo] = Hash.new
            fs = Hash.new

            dir = File.join($CONFIG[:result_abspath], repo)
            Dir.foreach dir do |f|
                fs[f[0..-6]] = :f if f =~ /^[a-z0-9]{40}-\d+-[A-Z]+-\d+\.yaml$/
            end
            @@cache[repo].delete_if { |k,v| fs[k].nil? }
            fs.each do |k,v|
                next if @@cache[repo][k]
                file = File.join($CONFIG[:result_abspath], repo, k+".yaml")
                report = YAML.load File.read(file) rescue nil
                next unless report
                report[:ok] ||= k.include?("OK") ? "OK" : "FAIL"
                report[:timestamp] ||= k.split('-')[1].to_i
                report[:ref] ||= ["UNKNOWN", ""]
                report[:result] ||= []
                report[:filter_commits] ||= []
                report[:tid] = k
                report[:head] ||= k.split('-')[0]

                @@cache[repo][k] = report
            end
            @@cache[repo]
        end
    end

    private
    def initialize
    end
end

get '/repo/:repo/' do
    repo = params[:repo]
	puts "bbbbbbbbbbbbbbbbbbbbbb#{repo}"
    halt 404 unless ReportCache.check_and_update repo
    cache = ReportCache[repo]
    halt 404 if cache.nil?
    @list = cache.sort_by {|k,v| v[:timestamp]}.reverse.map{|e| e[1]}
    @repo = repo
    erb :testlist
end

get '/repo/:repo/:tid' do
    repo = params[:repo]
    tid = params[:tid]
    halt 404 unless ReportCache.check_and_update repo
    cache = ReportCache[repo]
    halt 404 if cache.nil?
    @report = cache[tid]
    halt 404 if @report.nil?
    @repo = repo
    @tid = tid
    erb :result
end

get '/repo/:repo/:commit/:arch_or_lab/:testcase' do
    repo = params[:repo]
    commit = params[:commit]
    arch_or_lab = params[:arch_or_lab]
    testcase = params[:testcase]
    filepath = File.join($CONFIG[:result_abspath], repo, commit, arch_or_lab, testcase + ".error")
    @error = File.read(filepath).gsub(/\n/, '<br>') rescue "Error logs not found!"
    filepath = File.join($CONFIG[:result_abspath], repo, commit, arch_or_lab, testcase + ".log")
    @log = File.read(filepath).gsub(/\n/, '<br>') rescue "Error logs not found!"
    erb :error
end

get '/register' do
    if not $CONFIG[:registration][:frontend_enable]
        erb :no_register
    else
        repo = params[:repo]
        email = params[:email]
        is_public = params[:is_public] == "on" ? "true" : "false"
        if repo != nil and email != nil
            puts "#{REQUEST} append #{$CONFIG[:registration][:queue]}"
            `#{REQUEST} append #{$CONFIG[:registration][:queue]} "#{repo}|#{email}|#{is_public}|0"`
            erb :register_done
        else
            erb :register
        end
    end
end

get '/mooc_marking' do
    if not $CONFIG[:marking][:enable]
        halt 403, "marking is disabled"
    else
        id = params[:id]
        lab = params[:lab]
        if id != nil and lab != nil
            `#{REQUEST} append #{$CONFIG[:marking][:queue]} "#{id}|#{lab}"`
            halt 200, "request queued"
        else
            halt 400, "require id and lab"
        end
    end
end

get '/about' do
    erb :about
end

get '/' do
    @status_line = []
    begin
        Timeout.timeout(2) do
            s = TCPSocket.open($CONFIG[:ping][:frontend_addr], $CONFIG[:ping][:port])
            while l = s.gets
                @status_line << l.chomp
            end
            s.close
			puts "adadadasd#{@status_line}"
        end
    rescue Timeout::Error
        @status_line << "ERROR: Timeout to connect to backend!"
    rescue StandardError => e
        @status_line << "ERROR: Failed to connect to backend!"
    end
    @env = File.read(File.join(ROOT, "env.txt")) rescue "Unknown"
    puts "aaaaaaaaaaaaaaaaaaaaaaaaaaaa#{@status_line}"
    new_config_md5 = md5sum CONFIG_FILE
    if config_md5 != new_config_md5
        $CONFIG = YAML.load File.read(CONFIG_FILE)
        config_md5 = new_config_md5
    end
    @repos = $CONFIG[:repos]
    erb :index, :locals => {}
end

##
# Local variables:
# ruby-indent-level: 4
# End:
##
