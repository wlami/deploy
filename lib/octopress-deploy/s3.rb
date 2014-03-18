require 'find'
require 'fileutils'

module Octopress
  module Deploy
    class S3

      def initialize(options)
        begin
          require 'aws-sdk'
        rescue LoadError
          abort "Please install the aws-sdk gem first."
        end
        @options     = options
        @local       = options[:site_dir]
        @bucket_name = options[:bucket_name]
        @access_key  = options[:access_key_id]     || ENV['AWS_ACCESS_KEY_ID']
        @secret_key  = options[:secret_access_key] || ENV['AWS_SECRET_ACCESS_KEY']
        @region      = options[:region]            || ENV['AWS_DEFAULT_REGION'] || 'us-east-1'
        @remote_path = (options[:remote_path]      || '/').sub(/^\//,'')
        @verbose     = options[:verbose]           || true
        @delete      = options[:delete]
        @remote_path = @remote_path.sub(/^\//,'')  # remove leading slash
        @pull_dir    = options[:dir]
        connect
      end

      def push
        #abort "Seriously, you should. Quitting..." unless Deploy.check_gitignore
        @bucket = @s3.buckets[@bucket_name]
        if !@bucket.exists?
          abort "Bucket not found: '#{@bucket_name}'. Check your configuration or create a bucket using: `octopress deploy add_bucket`"
        else
          puts "Syncing #{@local} files to #{@bucket_name} on S3."
          write_files
          delete_files if delete_files?
          status_message
        end
      end

      def pull
        @bucket = @s3.buckets[@bucket_name]
        if !@bucket.exists?
          abort "Bucket not found: '#{@bucket_name}'. Check your configuration or create a bucket using: `octopress deploy add_bucket`"
        else
          puts "Syncing #{@bucket_name} files to #{@pull_dir} on S3."
          @bucket.objects.each do |object|
            path = File.join(@pull_dir, object.key)
            dir = File.dirname(path)
            FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
            File.open(path, 'w') { |f| f.write(object.read) }
          end
        end
      end

      # Connect to S3 using the AWS SDK
      # Retuns an aws bucket
      #
      def connect
        AWS.config(access_key_id: @access_key, secret_access_key: @secret_key, region: @region)
        @s3 = AWS.s3
      end

      # Write site files to the selected bucket
      #
      def write_files
        puts "Writing #{pluralize('file', site_files.size)}:" if @verbose
        site_files.each do |file| 
          o = @bucket.objects[remote_path(file)]
          o.write(file: file)
          if @verbose
            puts "+ #{remote_path(file)}"
          else
            progress('+')
          end
        end
      end

      # Delete files from the bucket, to ensure a 1:1 match with site files
      #
      def delete_files
        if deletable_files.size > 0
          puts "Deleting #{pluralize('file', deletable_files.size)}:" if @verbose
          deletable_files.each do |file|
            @bucket.objects.delete(file)
            if @verbose
              puts "- #{file}"
            else
              progress('-')
            end
          end
        end
      end

      # Create a new S3 bucket
      #
      def add_bucket
        puts @bucket_name
        @bucket = @s3.buckets.create(@bucket_name)
        puts "Created new bucket '#{@bucket_name}' in region '#{@region}'."
        configure_bucket
      end

      def configure_bucket
        error_page = @options['error_page'] || remote_path('404.html')
        index_page = @options['index_page'] || remote_path('index.html')

        config = @bucket.configure_website do |cfg|
          cfg.index_document_suffix = index_page
          cfg.error_document_key = error_page
        end
        puts "Bucket configured with index_document: #{index_page} and error_document: #{error_page}."
      end

      def delete_files?
        !!@delete
      end

      # local site files
      def site_files
        @site_files ||= Find.find(@local).to_a.reject do |f|
          File.directory?(f)
        end
      end

      # Destination paths for local site files.
      def site_files_dest
        @site_files_dest ||= site_files.map{|f| remote_path(f) }
      end

      # Replace local path with remote path
      def remote_path(file)
        File.join(@remote_path, file.sub(@local, '')).sub(/^\//, '')
      end

      # Files from the bucket which are deletable
      # Only deletes files beneath the remote_path if specified
      def deletable_files
        return [] unless delete_files?
        unless @deletable
          @deletable = @bucket.objects.map(&:key) - site_files_dest
          @deletable.reject!{|f| (f =~ /^#{@remote_path}/).nil? }
        end
        @deletable
      end

      # List written and deleted file counts
      def status_message
        uploaded = site_files.size
        deleted = deletable_files.size

        message =  "\nSuccess:".green + " #{uploaded} #{pluralize('file', uploaded)} uploaded"
        message << ", #{deleted} #{pluralize('file', deleted)} deleted."
        puts message
        configure_bucket unless @bucket.website?
      end

      # Print consecutive characters
      def progress(str)
        print str
        $stdout.flush
      end

      def pluralize(str, num)
        str << 's' if num != 1
        str
      end

      # Return default configuration options for this deployment type
      def self.default_config(options={})
        <<-CONFIG
#{"bucket_name: #{options[:bucket_name]}".ljust(40)}  # Name of the S3 bucket where these files will be stored.
#{"access_key_id: #{options[:access_key_id]}".ljust(40)}  # Get this from your AWS console at aws.amazon.com.
#{"secret_access_key: #{options[:secret_access_key]}".ljust(40)}  # Keep it safe; keep it secret. Keep this file in your .gitignore.
#{"remote_path: #{options[:remote_path] || '/'}".ljust(40)}  # relative path on bucket where files should be copied.

#{"# region: #{options[:region] || 'us-east-1'}".ljust(40)}  # Region where your bucket is located.
#{"# delete: #{options[:delete] || 'true'}".ljust(40)}  # Remove files from destination which do not match source files.
#{"# verbose: #{options[:verbose] || 'true'}".ljust(40)}  # Print out all file operations.
CONFIG
      end

    end
  end
end

