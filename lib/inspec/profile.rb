# encoding: utf-8
# Copyright 2015 Dominik Richter. All rights reserved.
# author: Dominik Richter
# author: Christoph Hartmann

require 'forwardable'
require 'inspec/fetcher'
require 'inspec/source_reader'
require 'inspec/metadata'

module Inspec
  class Profile # rubocop:disable Metrics/ClassLength
    extend Forwardable
    attr_reader :path

    def self.resolve_target(target, opts)
      # Fetchers retrieve file contents
      opts[:target] = target
      fetcher = Inspec::Fetcher.resolve(target)
      if fetcher.nil?
        fail("Could not fetch inspec profile in #{target.inspect}.")
      end
      # Source readers understand the target's structure and provide
      # access to tests, libraries, and metadata
      reader = Inspec::SourceReader.resolve(fetcher.relative_target)
      if reader.nil?
        fail("Don't understand inspec profile in #{target.inspect}, it "\
             "doesn't look like a supported profile structure.")
      end
      reader
    end

    def self.for_target(target, opts)
      new(resolve_target(target, opts), opts)
    end

    attr_reader :source_reader
    def_delegator :@source_reader, :tests
    def_delegator :@source_reader, :libraries
    def_delegator :@source_reader, :metadata

    # rubocop:disable Metrics/AbcSize
    def initialize(source_reader, options = nil)
      @options = options || {}
      @target = @options.delete(:target)
      @logger = @options[:logger] || Logger.new(nil)
      @source_reader = source_reader
      @profile_id = @options[:id]
      Metadata.finalize(@source_reader.metadata, @profile_id)
    end

    def params
      @params ||= load_params
    end

    def info
      res = params.dup
      rules = {}
      res[:rules].each do |gid, group|
        next if gid.to_s.empty?
        rules[gid] = { title: gid, rules: {} }
        group.each do |id, rule|
          next if id.to_s.empty?
          data = rule.dup
          data.delete(:checks)
          data[:impact] ||= 0.5
          data[:impact] = 1.0 if data[:impact] > 1.0
          data[:impact] = 0.0 if data[:impact] < 0.0
          rules[gid][:rules][id] = data
          # TODO: temporarily flatten the group down; replace this with
          # proper hierarchy later on
          rules[gid][:title] = data[:group_title]
        end
      end
      res[:rules] = rules
      res
    end

    # Check if the profile is internall well-structured. The logger will be
    # used to print information on errors and warnings which are found.
    #
    # @return [Boolean] true if no errors were found, false otherwise
    def check # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
      # initial values for response object
      result = {
        summary: {
          valid: false,
          timestamp: Time.now.iso8601,
          location: @target,
          profile: nil,
          controls: 0,
        },
        errors: [],
        warnings: [],
      }

      entry = lambda { |file, line, column, control, msg|
        {
          file: file,
          line: line,
          column: column,
          control_id: control,
          msg: msg,
        }
      }

      warn = lambda { |file, line, column, control, msg|
        @logger.warn(msg)
        result[:warnings].push(entry.call(file, line, column, control, msg))
      }

      error = lambda { |file, line, column, control, msg|
        @logger.error(msg)
        result[:errors].push(entry.call(file, line, column, control, msg))
      }

      @logger.info "Checking profile in #{@target}"
      meta_path = @source_reader.target.abs_path(@source_reader.metadata.ref)
      if meta_path =~ /metadata\.rb$/
        warn.call(@target, 0, 0, nil, 'The use of `metadata.rb` is deprecated. Use `inspec.yml`.')
      end

      # verify metadata
      m_errors, m_warnings = metadata.valid
      m_errors.each { |msg| error.call(meta_path, 0, 0, nil, msg) }
      m_warnings.each { |msg| warn.call(meta_path, 0, 0, nil, msg) }
      m_unsupported = metadata.unsupported
      m_unsupported.each { |u| warn.call(meta_path, 0, 0, nil, "doesn't support: #{u}") }
      @logger.info 'Metadata OK.' if m_errors.empty? && m_unsupported.empty?

      # extract profile name
      result[:summary][:profile] = metadata.params[:name]

      # check if the profile is using the old test directory instead of the
      # new controls directory
      if @source_reader.tests.keys.any? { |x| x =~ %r{^test/$} }
        warn.call(@target, 0, 0, nil, 'Profile uses deprecated `test` directory, rename it to `controls`.')
      end

      count = rules_count
      result[:summary][:controls] = count
      if count == 0
        warn.call(nil, nil, nil, nil, 'No controls or tests were defined.')
      else
        @logger.info("Found #{count} controls.")
      end

      # iterate over hash of groups
      params[:rules].each { |group, controls|
        @logger.info "Verify all controls in #{group}"
        controls.each { |id, control|
          sfile, sline = control[:source_location]
          error.call(sfile, sline, nil, id, 'Avoid controls with empty IDs') if id.nil? or id.empty?
          next if id.start_with? '(generated '
          warn.call(sfile, sline, nil, id, "Control #{id} has no title") if control[:title].to_s.empty?
          warn.call(sfile, sline, nil, id, "Control #{id} has no description") if control[:desc].to_s.empty?
          warn.call(sfile, sline, nil, id, "Control #{id} has impact > 1.0") if control[:impact].to_f > 1.0
          warn.call(sfile, sline, nil, id, "Control #{id} has impact < 0.0") if control[:impact].to_f < 0.0
          warn.call(sfile, sline, nil, id, "Control #{id} has no tests defined") if control[:checks].nil? or control[:checks].empty?
        }
      }

      # profile is valid if we could not find any error
      result[:summary][:valid] = result[:errors].empty?

      @logger.info 'Control definitions OK.' if result[:warnings].empty?
      result
    end

    def rules_count
      params[:rules].values.map { |hm| hm.values.length }.inject(:+) || 0
    end

    # generates a archive of a folder profile
    # assumes that the profile was checked before
    def archive(opts) # rubocop:disable Metrics/AbcSize
      profile_name = params[:name]
      ext = opts[:zip] ? 'zip' : 'tar.gz'

      if opts[:archive]
        archive = Pathname.new(opts[:archive])
      else
        slug = profile_name.downcase.strip.tr(' ', '-').gsub(/[^\w-]/, '_')
        archive = Pathname.new(Dir.pwd).join("#{slug}.#{ext}")
      end

      # check if file exists otherwise overwrite the archive
      if archive.exist? && !opts[:overwrite]
        @logger.info "Archive #{archive} exists already. Use --overwrite."
        return false
      end

      # remove existing archive
      File.delete(archive) if archive.exist?
      @logger.info "Generate archive #{archive}."

      # filter files that should not be part of the profile
      # TODO ignore all .files, but add the files to debug output

      # display all files that will be part of the archive
      @logger.debug 'Add the following files to archive:'
      root_path = @source_reader.target.prefix
      files = @source_reader.target.files
      files.each { |f| @logger.debug '    ' + f }

      if opts[:zip]
        # generate zip archive
        require 'inspec/archive/zip'
        zag = Inspec::Archive::ZipArchiveGenerator.new
        zag.archive(root_path, files, archive)
      else
        # generate tar archive
        require 'inspec/archive/tar'
        tag = Inspec::Archive::TarArchiveGenerator.new
        tag.archive(root_path, files, archive)
      end

      @logger.info 'Finished archive generation.'
      true
    end

    private

    def load_params
      params = @source_reader.metadata.params
      params[:name] = @profile_id unless @profile_id.nil?
      params[:rules] = rules = {}
      prefix = @source_reader.target.prefix || ''

      # we're checking a profile, we don't care if it runs on the host machine
      opts = @options.dup
      opts[:ignore_supports] = true
      runner = Runner.new(
        id: @profile_id,
        backend: :mock,
        test_collector: opts.delete(:test_collector),
      )
      runner.add_profile(self, opts)

      runner.rules.each do |id, rule|
        file = rule.instance_variable_get(:@__file)
        file = file[prefix.length..-1] if file.start_with?(prefix)
        rules[file] ||= {}
        rules[file][id] = {
          title: rule.title,
          desc: rule.desc,
          impact: rule.impact,
          checks: rule.instance_variable_get(:@checks),
          code: rule.instance_variable_get(:@__code),
          source_location: rule.instance_variable_get(:@__source_location),
          group_title: rule.instance_variable_get(:@__group_title),
        }
      end

      @profile_id ||= params[:name]
      params
    end
  end
end
