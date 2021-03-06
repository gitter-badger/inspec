# encoding: utf-8
# author: Christoph Hartmann
# author: Dominik Richter

module Inspec::Resources
  class JsonConfig < Inspec.resource(1)
    name 'json'
    desc 'Use the json InSpec audit resource to test data in a JSON file.'
    example "
      describe json('policyfile.lock.json') do
        its('cookbook_locks.omnibus.version') { should eq('2.2.0') }
      end
    "

    # make params readable
    attr_reader :params

    def initialize(path)
      @path = path
      @file = inspec.file(@path)
      @file_content = @file.content

      # check if file is available
      if !@file.file?
        skip_resource "Can't find file \"#{@conf_path}\""
        return @params = {}
      end

      # check if file is readable
      if @file_content.empty? && @file.size > 0
        skip_resource "Can't read file \"#{@conf_path}\""
        return @params = {}
      end

      @params = parse(@file_content)
    end

    def parse(content)
      require 'json'
      JSON.parse(content)
    end

    def value(key)
      extract_value(key, @params)
    end

    # Shorthand to retrieve a parameter name via `#its`.
    # Example: describe json('file') { its('paramX') { should eq 'Y' } }
    #
    # @param [String] name name of the field to retrieve
    # @return [Object] the value stored at this position
    def method_missing(*keys)
      # catch bahavior of rspec its implementation
      # @see https://github.com/rspec/rspec-its/blob/master/lib/rspec/its.rb#L110
      keys.shift if keys.is_a?(Array) && keys[0] == :[]
      value(keys)
    end

    def to_s
      "Json #{@path}"
    end

    private

    def extract_value(keys, value)
      key = keys.shift
      return nil if key.nil?

      # if value is an array, iterate over each child
      if value.is_a?(Array)
        value = value.map { |i|
          extract_value([key], i)
        }
      else
        value = value[key.to_s].nil? ? nil : value[key.to_s]
      end

      # if there are no more keys, just return the value
      return value if keys.first.nil?
      # if there are more keys, extract more
      extract_value(keys.clone, value)
    end
  end
end
