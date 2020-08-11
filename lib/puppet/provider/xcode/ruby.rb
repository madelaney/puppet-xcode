Puppet::Type.type(:xcode).provide(:ruby) do
  desc 'Installs the Xcode dmg provided.'

  commands :move    => '/bin/mv'
  commands :hdiutil => '/usr/bin/hdiutil'
  commands :curl    => '/usr/bin/curl'
  commands :ditto   => '/usr/bin/ditto'
  commands :xiputil => '/usr/bin/xip'

  MANIFEST_DIR = '/var/db'.freeze

  def self.extract_version(source)
    if source.end_with? '.dmg'
      metadata = /.*(Xcode_([0-9\.?]+){1,})\.dmg/.match source
      version = metadata[2]
    elsif source.end_with? '.xip'
      metadata = /.*(Xcode_?([0-9\.?]+){1,})(_(beta(_?[0-9]?)))?\.xip/.match source
      version = metadata[2]
      version = format('%s-%s', version, metadata[4]) unless metadata[4].nil?
    end
    version
  end

  def self.install_dir(resource)
    root = resource[:install_path] ? resource[:install_path] : '/Applications'
    version = extract_version resource[:source]

    bundle = format('Xcode-v%s.app', version)
    path = File.join(root, bundle)

    path
  end

  def self.xcselect(install_path)
    path = format('%s/Contents/Developer', install_path)
    xcodeselect = format('/usr/bin/xcode-select -s %s', path)
    Puppet.debug xcodeselect
    Open3.popen3(xcodeselect.chomp, :chdir => path) do |_i, o, e, _t|
      e.each { |err| puts err }
      o.each { |out| puts out }
    end
  end

  def self.accepteula(install_path)
    path = format('%s/Contents/Developer/usr/bin', install_path)
    xcodebuild = format('%s/xcodebuild -license accept', path)
    Puppet.debug xcodebuild
    Open3.popen3(xcodebuild.chomp, :chdir => path) do |_i, o, e, _t|
      e.each { |err| puts err }
      o.each { |out| puts out }
    end
  end

  def self.save_metadata(name, opts)
    Puppet.debug "Writing manifest: #{name}"
    File.open(name, 'w') do |t|
      opts.each { |k, v| t.write format("%s: %s\n", k, v) }
    end
  end

  def self.installapp(source, install_path)
    ditto '--rsrc', source, install_path
  end

  def self.install_xcode(source, name, version, install_dir, opts = {})
    cached_source = source
    tmpdir = Dir.mktmpdir

    if source.end_with? '.xip'
      installxip cached_source, install_dir
    else
      installpkgdmg cached_source, name, install_dir
    end

    meta_data = {
      name: name,
      version: version,
      source: source,
      install_dir: install_dir
    }.merge(opts)

    if !opts[:eula].casecmp 'accept'
      Puppet.debug 'Accepting EULA'
      accepteula install_dir
    end

    if !opts[:selected].casecmp 'yes'
      Puppet.debug 'Selecting Xcode'
      xcselect install_dir
    end

    save_metadata(opts[:manifest], meta_data)
  end

  def self.installxip(source, install_dir)
    xiputil '--expand', source
    extract_dir = File.dirname(source)

    if Dir.exist? "#{extract_dir}/Xcode-beta.app"
      move "#{extract_dir}/Xcode-beta.app", install_dir
    else
      move "#{extract_dir}/Xcode.app", install_dir
    end
  end

  def self.installpkgdmg(source, name, install_dir)
    begin
      mount_point = Dir.mktmpdir
      open(source) do |dmg|
        hdiutil 'mount',
                '-nobrowse',
                '-readonly',
                '-mountpoint',
                mount_point,
                dmg.path

        mounts = [mount_point]

        begin
          found_app = false
          mounts.each do |fspath|
            Puppet.debug "trying [#{fspath}]."
            Dir.entries(fspath).select { |f|
              f =~ /Xcode\.app$/i
            }.each do |pkg|
              found_app = true
              installapp("#{fspath}/#{pkg}", install_dir)
            end
          end
          Puppet.debug "Unable to find .app in .appdmg. #{name} will not be installed." unless found_app
        ensure
          hdiutil 'eject', mounts[0]
        end
      end
    rescue StandardError => e
      Puppet.debug e.message
    ensure
      FileUtils.remove_entry_secure(mount_point, true)
    end
  end

  def create
    version = self.class.extract_version @resource[:source]
  end

  def query
    Puppet::FileSystem.exist?(install_manifest) ? {:name => @resource[:name], :ensure => :present} : {:name => @resource[:name], :ensure => :mising}
  end

  def install
    raise "Xcode PKG DMG's must specify a package source." if @resource[:source].nil?
    raise "Xcode PKG DMG's must specify a package name." if @resource[:name].nil?

    version = self.class.extract_version @resource[:source]

    begin
      install_dir = self.class.install_dir @resource
      opts = {
        manifest: install_manifest,
        eula: @resource[:eula],
        selected: @resource[:selected],
        checksum: @resource[:checksum],
        checksum_type: @resource[:checksum_type]
      }

      self.class.install_xcode(@resource[:source],
                               @resource[:name],
                               version,
                               install_dir,
                               opts)

    rescue StandardError => e
      Puppet.debug e.message
      Puppet.debug e.backtrace
    end
  end

  def uninstall
    version = self.class.extract_version @resource[:source]
    notice("Destroying: #{resource[:name]}@#{version}")
    begin
      if File.exist? install_manifest
        manifest = YAML.load_file install_manifest
        if manifest.key? 'install_dir'
          install_dir = manifest['install_dir']
          FileUtils.rm_rf install_dir if File.exist? install_dir
        end

        FileUtils.rm_rf install_manifest
      end
    rescue StandardError => e
      Puppet.debug e.message
      Puppet.debug e.backtrace
    end
  end

  def exists?
    manifest = install_manifest
    Puppet.debug format('Install Manifest: %s', install_manifest)
    Puppet::FileSystem.exist? manifest
  end

  def install_manifest
    filename = format('.%s', File.basename(@resource[:source]))
    [MANIFEST_DIR, filename].join File::SEPARATOR
  end
end
