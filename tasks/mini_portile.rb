require 'rbconfig'
require 'net/http'
require 'fileutils'
require 'tempfile'

class MiniPortile
  attr_reader :name, :version, :target
  attr_accessor :host, :files, :log

  def initialize(name, version, target)
    @name = name
    @version = version
    @target = target
    @files = []
    @log = STDOUT

    @host = RbConfig::CONFIG['arch']
  end

  def download
    @files.each do |url|
      filename = File.basename(url)
      download_file(url, File.join(archives_path, filename))
    end
  end

  def extract
    @files.each do |url|
      filename = File.basename(url)
      extract_file(File.join(archives_path, filename), tmp_path)
    end
  end

  def configure
    return if configured?

    prefix  = File.expand_path(port_path)
    options = [
      "--disable-shared",   # disable generation of shared object
      "--enable-static",    # build static library
      "--prefix=#{prefix}"  # installation target
    ].join(' ')

    execute('configure', %Q(sh configure #{options}))
  end

  def compile
    execute('compile', 'make')
  end

  def install
    return if installed?
    execute('install', %Q(make install))
  end

  def downloaded?
    missing = @files.detect do |url|
      filename = File.basename(url)
      !File.exist?(File.join(archives_path, filename))
    end

    missing ? false : true
  end

  def configured?
    configure = File.join(work_path, 'configure')
    makefile  = File.join(work_path, 'Makefile')

    newer?(makefile, configure)
  end

  def installed?
    makefile  = File.join(work_path, 'Makefile')
    target_dir = Dir.glob("#{port_path}/*").find { |d| File.directory?(d) }

    newer?(target_dir, makefile)
  end

  def cook
    download unless downloaded?
    extract
    configure unless configured?
    compile
    install unless installed?

    return true
  end

  def activate
    vars = {
      'PATH'          => File.join(port_path, 'bin'),
      'CPATH'         => File.join(port_path, 'include'),
      'LIBRARY_PATH'  => File.join(port_path, 'lib')
    }.reject { |env, path| !File.directory?(path) }

    @log.puts "Activating #{@name} #{@version} (from #{port_path})..."
    vars.each do |var, path|
      full_path = File.expand_path(path)

      # turn into a valid Windows path (if required)
      full_path.gsub!(File::SEPARATOR, File::ALT_SEPARATOR) if File::ALT_SEPARATOR

      # save current variable value
      old_value = ENV[var] || ''

      unless old_value.include?(full_path)
        ENV[var] = "#{full_path}#{File::PATH_SEPARATOR}#{old_value}"
      end
    end
  end

private

  def tmp_path
    @tmp_path ||= "tmp/#{@host}/ports/#{@name}/#{@version}"
  end

  def port_path
    @port_path ||= "#{@target}/#{@host}/#{@name}/#{@version}"
  end

  def archives_path
    @archives_path ||= "#{@target}/archives"
  end

  def work_path
    @work_path ||= begin
      Dir.glob("#{tmp_path}/*").find { |d| File.directory?(d) }
    end
  end

  def log_file(action)
    File.join(tmp_path, "#{action}.log")
  end

  def extract_file(file, target)
    filename = File.basename(file)
    FileUtils.mkdir_p target

    @log.write "Extracting #{filename} into #{target}... "
    output = `tar xf #{file} -C #{target}`
    if $?.success?
      @log.puts "OK"
    else
      @log.puts "ERROR"
      @log.puts output
      raise "Failed to complete extract task"
    end
  end

  def execute(action, command)
    log        = log_file(action)
    log_out    = File.expand_path(log)
    redirected = command << " 2>&1 >#{log_out}"

    Dir.chdir work_path do
      @log.print "Running '#{action}' for #{@name} #{@version}... "
      system redirected
      if $?.success?
        @log.puts "OK"
        return true
      else
        @log.puts "ERROR, review '#{log}' to see what happened."
        raise "Failed to complete #{action} task"
      end
    end
  end

  def newer?(target, checkpoint)
    if (target && File.exist?(target)) && (checkpoint && File.exist?(checkpoint))
      File.mtime(target) > File.mtime(checkpoint)
    else
      false
    end
  end

  # Slighly modified from RubyInstaller uri_ext, Rubinius configure
  # and adaptations of Wayne's RailsInstaller
  def download_file(url, full_path, count = 3)
    return if File.exist?(full_path)
    filename = File.basename(full_path)

    begin

      if ENV['http_proxy']
        protocol, userinfo, host, port  = URI::split(ENV['http_proxy'])
        proxy_user, proxy_pass = userinfo.split(/:/) if userinfo
        http = Net::HTTP::Proxy(host, port, proxy_user, proxy_pass)
      else
        http = Net::HTTP
      end

      @log.write "Downloading #{filename}"
      http.get_response(URI.parse(url)) do |response|
        case response
        when Net::HTTPNotFound
          @log.puts "404 - Not Found"
          return false

        when Net::HTTPClientError
          @log.puts "Error: Client Error: #{response.inspect}"
          return false

        when Net::HTTPRedirection
          raise "Too many redirections for the original URL, halting." if count <= 0
          url = response["location"]
          return download_file(url, full_path, count - 1)

        when Net::HTTPOK
          temp_file = Tempfile.new("download-#{filename}")
          temp_file.binmode

          size = 0
          progress = 0
          total = response.header["Content-Length"].to_i

          response.read_body do |chunk|
            temp_file << chunk
            size += chunk.size
            new_progress = (size * 100) / total
            unless new_progress == progress
              @log.print "\rDownloading %s (%3d%%) " % [filename, new_progress]
            end
            progress = new_progress
          end

          @log.puts

          temp_file.close
          File.unlink full_path if File.exists?(full_path)
          FileUtils.mkdir_p File.dirname(full_path)
          FileUtils.mv temp_file.path, full_path, :force => true
        end
      end

    rescue Exception => e
      File.unlink full_path if File.exists?(full_path)
      @log.puts "ERROR: #{e.message}"
      return false
    end
  end
end