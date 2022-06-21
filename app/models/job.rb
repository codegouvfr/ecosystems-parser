class Job < ApplicationRecord
  validates_presence_of :url
  validates_uniqueness_of :id

  def check_status
    return if sidekiq_id.blank?
    return if finished?
    update(status: Sidekiq::Status.status(sidekiq_id))
  end

  def finished?
    ['complete', 'error'].include?(status)
  end

  def start_dependency_parsing
    if fast_parse?
      perform_dependency_parsing
    else
      parse_dependencies_async
    end
  end

  def parse_dependencies_async
    sidekiq_id = ParseDependenciesWorker.perform_async(id)
    update(sidekiq_id: sidekiq_id)
  end

  def fast_parse?
    # TODO check size (head request)
    return true if single_parsable_file? 
  end

  def perform_dependency_parsing
    begin
      Dir.mktmpdir do |dir|
        sha256 = download_file(dir)
        results = parse_dependencies(dir)
        update!(results: results, status: 'complete', sha256: sha256)
      end
    rescue => e
      update(results: {error: e.inspect}, status: 'error')
    end
  end

  def parse_dependencies(dir)
    path = working_directory(dir)

    case mime_type(path)
    when "application/zip"
      destination = File.join([dir, 'zip'])
      `unzip -oqj #{path} -d #{destination}`
      results = Bibliothecary.analyse(destination)
    when "application/gzip"
      destination = File.join([dir, 'tar'])
      `mkdir #{destination} && tar xzf #{path} -C #{destination} --strip-components 1`
      results = Bibliothecary.analyse(destination)
    when "text/plain", "application/json" # TODO there will be other mime types that need to be supported here
      results = Bibliothecary.analyse_file(basename, File.open(path).read)
    else
      results = []
    end

    return { manifests: results.map{|m| m.transform_keys{ |key| key == :platform ? :ecosystem : key }}}
  end

  def download_file(dir)
    path = working_directory(dir)
    downloaded_file = File.open(path, "wb")

    request = Typhoeus::Request.new(url, followlocation: true)
    request.on_headers do |response|
      return nil if response.code != 200
    end
    request.on_body { |chunk| downloaded_file.write(chunk) }
    request.on_complete { downloaded_file.close }
    request.run

    return Digest::SHA256.hexdigest File.read(path)
  end

  def mime_type(path)
    IO.popen(
      ["file", "--brief", "--mime-type", path],
      in: :close, err: :close
    ) { |io| io.read.chomp }
  end

  def single_parsable_file?
    Bibliothecary.identify_manifests([basename]).any?
  end

  def working_directory(dir)
    File.join([dir, basename])
  end

  def basename
    File.basename(url)
  end

  def self.formats
    {
      bower: [
        "bower.json"
      ],
      cargo: [
        "Cargo.toml",
        "Cargo.lock"
      ],
      carthage: [
        "Cartfile",
        "Cartfile.private",
        "Cartfile.resolved"
      ],
      clojars: [
        "project.clj"
      ],
      cocoapods: [
        "Podfile",
        "Podfile.lock",
        "*.podspec",
        "*.podspec.json"
      ],
      conda: [
        "environment.yml",
        "environment.yaml",
        "environment.yml.lock",
        "environment.yaml.lock"
      ],
      cpan: [
        "META.json",
        "META.yml"
      ],
      cran: [
        "DESCRIPTION"
      ],
      cyclonedx: [
        "cyclonedx.xml",
        "cyclonedx.json"
      ],
      dub: [
        "dub.json",
        "dub.sdl"
      ],
      elm: [
        "elm-package.json",
        "elm_dependencies.json",
        "elm-stuff/exact-dependencies.json"
      ],
      go: [
        "glide.yaml",
        "glide.lock",
        "Godeps",
        "Godeps/Godeps.json",
        "vendor/manifest",
        "vendor/vendor.json",
        "Gopkg.toml",
        "Gopkg.lock",
        "go.mod",
        "go.sum",
        "go-resolved-dependencies.json"
      ],
      hackage: [
        "*.cabal",
        "cabal.config"
      ],
      haxelib: [
        "haxelib.json"
      ],
      hex: [
        "mix.exs",
        "mix.lock"
      ],
      julia: [
        "REQUIRE"
      ],
      maven: [
        "pom.xml",
        "ivy.xml",
        "build.gradle",
        "build.gradle.kts",
        "gradle-dependencies-q.txt",
        "maven-resolved-dependencies.txt",
        "sbt-update-full.txt",
        "maven-dependency-tree.txt"
      ],
      meteor: [
        "versions.json"
      ],
      npm: [
        "package.json",
        "package-lock.json",
        "npm-shrinkwrap.json",
        "yarn.lock",
        "npm-ls.json"
      ],
      nuget: [
        "packages.config",
        "packages.lock.json",
        "Project.json",
        "Project.lock.json",
        "*.nuspec",
        "paket.lock",
        "*.csproj",
        "project.assets.json"
      ],
      packagist: [
        "composer.json",
        "composer.lock"
      ],
      pub: [
        "pubspec.yaml",
        "pubspec.lock"
      ],
      pypi: [
        "setup.py",
        "req*.txt",
        "req*.pip",
        "requirements/*.txt",
        "requirements/*.pip",
        "requirements.frozen",
        "pip-resolved-dependencies.txt",
        "Pipfile",
        "Pipfile.lock",
        "pyproject.toml",
        "poetry.lock"
      ],
      rubygems: [
        "Gemfile",
        "Gemfile.lock",
        "gems.rb",
        "gems.locked",
        "*.gemspec"
      ],
      shards: [
        "shard.yml",
        "shard.lock"
      ],
      swift: [
        "Package.swift"
      ]
    }
  end
end
