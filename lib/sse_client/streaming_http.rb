require "http_tools"
require "socketry"

module SSE
  #
  # Wrapper around a socket providing a simplified HTTP request-response cycle including streaming.
  # The socket is created and managed by Socketry, which we use so that we can have a read timeout.
  #
  class StreamingHTTPConnection
    def initialize(uri, proxy, headers, connect_timeout, read_timeout)
      if proxy
        @socket = open_socket(proxy, connect_timeout)
        @socket.write(build_proxy_request(uri, proxy))
      else
        @socket = open_socket(uri, connect_timeout)
      end

      @socket.write(build_request(uri, headers))

      @reader = HTTPResponseReader.new(@socket, read_timeout)
    end

    def close
      @socket.close if @socket
      @socket = nil
    end

    def status
      @reader.status
    end

    def headers
      @reader.headers
    end

    # Generator that returns one line of the response body at a time (delimited by \r, \n,
    # or \r\n) until the response is fully consumed or the socket is closed.
    def read_lines
      @reader.read_lines
    end

    # Consumes the entire response body and returns it.
    def read_all
      @reader.read_all
    end

    private

    def open_socket(uri, connect_timeout)
      if uri.scheme == 'https'
        Socketry::SSL::Socket.connect(uri.host, uri.port, timeout: connect_timeout)
      else
        Socketry::TCP::Socket.connect(uri.host, uri.port, timeout: connect_timeout)
      end
    end

    # Build an HTTP request line and headers.
    def build_request(uri, headers)
      ret = "GET #{uri.request_uri} HTTP/1.1\r\n"
      headers.each { |k, v|
        ret << "#{k}: #{v}\r\n"
      }
      ret + "\r\n"
    end

    # Build a proxy connection header.
    def build_proxy_request(uri, proxy)
      ret = "CONNECT #{uri.host}:#{uri.port} HTTP/1.1\r\n"
      ret << "Host: #{uri.host}:#{uri.port}\r\n"
      if proxy.user || proxy.password
        encoded_credentials = Base64.strict_encode64([proxy.user || '', proxy.password || ''].join(":"))
        ret << "Proxy-Authorization: Basic #{encoded_credentials}\r\n"
      end
      ret << "\r\n"
      ret
    end
  end

  #
  # Used internally to read the HTTP response, either all at once or as a stream of text lines.
  # Incoming data is fed into an instance of HTTPTools::Parser, which gives us the header and
  # chunks of the body via callbacks.
  #
  class HTTPResponseReader
    DEFAULT_CHUNK_SIZE = 10000

    attr_reader :status, :headers

    def initialize(socket, read_timeout)
      @socket = socket
      @read_timeout = read_timeout
      @parser = HTTPTools::Parser.new
      @buffer = ""
      @done = false
      @lock = Mutex.new

      # Provide callbacks for the Parser to give us the headers and body. This has to be done
      # before we start piping any data into the parser.
      have_headers = false
      @parser.on(:header) do
        have_headers = true
      end
      @parser.on(:stream) do |data|
        @lock.synchronize { @buffer << data }  # synchronize because we're called from another thread in Socketry
      end
      @parser.on(:finish) do
        @lock.synchronize { @done = true }
      end

      # Block until the status code and headers have been successfully read.
      while !have_headers
        raise EOFError if !read_chunk_into_buffer
      end
      @headers = Hash[@parser.header.map { |k,v| [k.downcase, v] }]
      @status = @parser.status_code
    end

    def read_lines
      Enumerator.new do |gen|
        loop do
          line = read_line
          break if line.nil?
          gen.yield line
        end
      end
    end

    def read_all
      while read_chunk_into_buffer
      end
      @buffer
    end

    private

    # Attempt to read some more data from the socket. Return true if successful, false if EOF.
    # A read timeout will result in an exception from Socketry's readpartial method.
    def read_chunk_into_buffer
      # If @done is set, it means the Parser has signaled end of response body
      @lock.synchronize { return false if @done }
      data = @socket.readpartial(DEFAULT_CHUNK_SIZE, timeout: @read_timeout)
      return false if data == :eof
      @parser << data
      # We are piping the content through the parser so that it can handle things like chunked
      # encoding for us. The content ends up being appended to @buffer via our callback.
      true
    end

    # Extract the next line of text from the read buffer, refilling the buffer as needed.
    def read_line
      loop do
        @lock.synchronize do
          i = @buffer.index(/[\r\n]/)
          if !i.nil?
            i += 1 if (@buffer[i] == "\r" && i < @buffer.length - 1 && @buffer[i + 1] == "\n")
            return @buffer.slice!(0, i + 1).force_encoding(Encoding::UTF_8)
          end
        end
        return nil if !read_chunk_into_buffer
      end
    end
  end
end
