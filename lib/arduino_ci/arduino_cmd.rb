require 'fileutils'

module ArduinoCI

  # Wrap the Arduino executable.  This requires, in some cases, a faked display.
  class ArduinoCmd

    # Enable a shortcut syntax for command line flags
    # @param name [String] What the flag will be called (prefixed with 'flag_')
    # @return [void]
    # @macro [attach] flag
    #   @!attribute [r] flag_$1
    #   @return String $2 the text of the command line flag
    def self.flag(name, text = nil)
      text = "(flag #{name} not defined)" if text.nil?
      self.class_eval("def flag_#{name};\"#{text}\";end")
    end

    attr_accessor :installation
    attr_accessor :base_cmd

    attr_reader   :library_is_indexed
    attr_reader   :last_out
    attr_reader   :last_err
    attr_reader   :last_msg

    # set the command line flags (undefined for now).
    # These vary between gui/cli
    flag :get_pref
    flag :set_pref
    flag :save_prefs
    flag :use_board
    flag :install_boards
    flag :install_library
    flag :verify

    def initialize
      @prefs_cache        = {}
      @prefs_fetched      = false
      @library_is_indexed = false
      @last_out           = ""
      @last_err           = ""
      @last_msg           = ""
    end

    def parse_pref_string(arduino_output)
      lines = arduino_output.split("\n").select { |l| l.include? "=" }
      ret = lines.each_with_object({}) do |e, acc|
        parts = e.split("=", 2)
        acc[parts[0]] = parts[1]
        acc
      end
      ret
    end

    def _lib_dir
      "<lib dir not defined>"
    end

    # fetch preferences to a string
    def _prefs_raw
      resp = run_and_capture(flag_get_pref)
      return nil unless resp[:success]
      resp[:out]
    end

    def prefs
      prefs_raw = _prefs_raw unless @prefs_fetched
      return nil if prefs_raw.nil?
      @prefs_cache = parse_pref_string(prefs_raw)
      @prefs_cache.clone
    end

    # get a preference key
    def get_pref(key)
      data = @prefs_fetched ? @prefs_cache : prefs
      data[key]
    end

    # underlying preference-setter.
    # @return [bool] whether the command succeeded
    def _set_pref(key, value)
      run_and_capture(flag_set_pref, "#{key}=#{value}", flag_save_prefs)[:success]
    end

    # set a preference key/value pair, and update the cache.
    # @param key [String] the preference key
    # @param value [String] the preference value
    # @return [bool] whether the command succeeded
    def set_pref(key, value)
      success = _set_pref(key, value)
      @prefs_cache[key] = value if success
      success
    end

    # run the arduino command
    def _run(*args, **kwargs)
      raise "Ian needs to implement this in a subclass #{args} #{kwargs}"
    end

    # build and run the arduino command
    def run(*args, **kwargs)
      # do some work to extract & merge environment variables if they exist
      has_env = !args.empty? && args[0].class == Hash
      env_vars = has_env ? args[0] : {}
      actual_args = has_env ? args[1..-1] : args  # need to shift over if we extracted args
      full_args = @base_cmd + actual_args
      full_cmd = env_vars.empty? ? full_args : [env_vars] + full_args

      shell_vars = env_vars.map { |k, v| "#{k}=#{v}" }.join(" ")
      @last_msg = " $ #{shell_vars} #{full_args.join(' ')}"
      _run(*full_cmd, **kwargs)
    end

    # run a command and capture its output
    # @return [Hash] {:out => String, :err => String, :success => bool}
    def run_and_capture(*args, **kwargs)
      pipe_out, pipe_out_wr = IO.pipe
      pipe_err, pipe_err_wr = IO.pipe
      our_kwargs = { out: pipe_out_wr, err: pipe_err_wr }
      eventual_kwargs = our_kwargs.merge(kwargs)
      success = run(*args, **eventual_kwargs)
      pipe_out_wr.close
      pipe_err_wr.close
      str_out = pipe_out.read
      str_err = pipe_err.read
      pipe_out.close
      pipe_err.close
      @last_err = str_err
      @last_out = str_out
      { out: str_out, err: str_err, success: success }
    end

    # run a command and don't capture its output, but use the same signature
    # @return [Hash] {:out => String, :err => String, :success => bool}
    def run_wrap(*args, **kwargs)
      success = run(*args, **kwargs)
      { out: "NOPE, use run_and_capture", err: "NOPE, use run_and_capture", success: success }
    end

    # check whether a board is installed
    # we do this by just selecting a board.
    #   the arduino binary will error if unrecognized and do a successful no-op if it's installed
    def board_installed?(boardname)
      run_and_capture(flag_use_board, boardname)[:success]
    end

    # install a board by name
    # @param name [String] the board name
    # @return [bool] whether the command succeeded
    def install_boards(boardfamily)
      # TODO: find out why IO.pipe fails but File::NULL succeeds :(
      result = run_and_capture(flag_install_boards, boardfamily)
      already_installed = result[:err].include?("Platform is already installed!")
      result[:success] || already_installed
    end

    # install a library by name
    # @param name [String] the library name
    # @return [bool] whether the command succeeded
    def install_library(library_name)
      # workaround for https://github.com/arduino/Arduino/issues/3535
      # use a dummy library name but keep open the possiblity that said library
      # might be selected by choice for installation
      workaround_lib = "USBHost"
      unless @library_is_indexed || workaround_lib == library_name
        @library_is_indexed = run_and_capture(flag_install_library, workaround_lib)
      end

      # actual installation
      result = run_and_capture(flag_install_library, library_name)

      # update flag if necessary
      @library_is_indexed = (@library_is_indexed || result[:success]) if library_name == workaround_lib
      result[:success]
    end

    # generate the (very likely) path of a library given its name
    def library_path(library_name)
      File.join(_lib_dir, library_name)
    end

    # update the library index
    def update_library_index
      # install random lib so the arduino IDE grabs a new library index
      # see: https://github.com/arduino/Arduino/issues/3535
      install_library("USBHost")
    end

    # use a particular board for compilation
    def use_board(boardname)
      run_and_capture(flag_use_board, boardname, flag_save_prefs)[:success]
    end

    # use a particular board for compilation, installing it if necessary
    def use_board!(boardname)
      return true if use_board(boardname)
      boardfamily = boardname.split(":")[0..1].join(":")
      puts "Board '#{boardname}' not found; attempting to install '#{boardfamily}'"
      return false unless install_boards(boardfamily) # guess board family from first 2 :-separated fields
      use_board(boardname)
    end

    def verify_sketch(path)
      ext = File.extname path
      unless ext.casecmp(".ino").zero?
        @last_msg = "Refusing to verify sketch with '#{ext}' extension -- rename it to '.ino'!"
        return false
      end
      unless File.exist? path
        @last_msg = "Can't verify Sketch at nonexistent path '#{path}'!"
        return false
      end
      ret = run_and_capture(flag_verify, path)
      ret[:success]
    end

    # ensure that the given library is installed, or symlinked as appropriate
    # return the path of the prepared library, or nil
    def install_local_library(path)
      realpath = File.expand_path(path)
      library_name = File.basename(realpath)
      destination_path = library_path(library_name)

      # things get weird if the sketchbook contains the library.
      # check that first
      if File.exist? destination_path
        uhoh = "There is already a library '#{library_name}' in the library directory"
        return destination_path if destination_path == realpath

        # maybe it's a symlink? that would be OK
        if File.symlink?(destination_path)
          return destination_path if File.readlink(destination_path) == realpath
          @last_msg = "#{uhoh} and it's not symlinked to #{realpath}"
          return nil
        end

        @last_msg = "#{uhoh}.  It may need to be removed manually."
        return nil
      end

      # install the library
      FileUtils.ln_s(realpath, destination_path)
      destination_path
    end

    def library_examples(installed_library_path)
      example_path = File.join(installed_library_path, "examples")
      examples = Pathname.new(example_path).children.select(&:directory?).map(&:to_path).map(&File.method(:basename))
      files = examples.map do |e|
        proj_file = File.join(example_path, e, "#{e}.ino")
        File.exist?(proj_file) ? proj_file : nil
      end
      files.reject(&:nil?)
    end
  end
end
