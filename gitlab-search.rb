#!/usr/bin/env ruby

require 'dotenv/load'
require 'optparse'
require 'fileutils'
require 'gitlab'
require 'json'
require 'ostruct'

def configure_gitlab(hostname, gitlab_access_token)
  Gitlab.configure do |config|
    config.endpoint = "https://#{hostname}/api/v4"
    config.private_token = gitlab_access_token
    # config.user_agent   = 'Custom User Agent'          # user agent, default: 'Gitlab Ruby Gem [version]'
  end
end

def get_relevant_projects(tmp_dir, bust_cache = false)
  project_ids_cache_file = File.join(tmp_dir, 'projects_list_cache.json')
  if bust_cache
    File.delete project_ids_cache_file if File.exists? project_ids_cache_file
  end

  if File.exists? project_ids_cache_file
    STDERR.puts('Using cached repository list')
    return(JSON.parse(File.read project_ids_cache_file))
  else
    projects =
      Gitlab
        .projects(
          per_page: 1000,
          options: {
            archived: false,
            min_access_level: 10, # Guest https://docs.gitlab.com/ee/api/members.html#roles
          },
        )
        .auto_paginate
        .select { |p| !p.empty_repo && p.import_status != 'failed' }
        .map { |p| { id: p.id, name: p.name, homepage: p.web_url } }

    File.write(project_ids_cache_file, JSON.generate(projects))

    return projects
  end
end

def find_files(projects, tmp_dir, bust_cache = false)
  files_cache_file = File.join(tmp_dir, 'projects_files_cache.json')
  if bust_cache
    File.delete files_cache_file if File.exists? files_cache_file
  end

  if File.exists? files_cache_file
    STDERR.puts('Using cached files list')
    return JSON.parse(File.read files_cache_file)
  else
    files =
      projects
        .map do |p|
          project = OpenStruct.new p
          res = Gitlab.tree(project.id)
          paths = res.select { |p| p.path.match /erfile$/ }.map { |p| p.path }

          { project: p, paths: paths }
        rescue StandardError
          STDERR.puts "Error reading files for #{project.id}"
        end
        .select { |files| files[:paths].length > 0 }

    File.write(files_cache_file, JSON.generate(files))

    return files
  end
end

def find_content_in_files(project_files)
  project_files
    .map { |p| OpenStruct.new p }
    .map do |p|
      p.project = OpenStruct.new p.project
      p
    end
    .map do |p|
      {
        project: p.project,
        files:
          p.paths.select do |file|
            Gitlab.file_contents(p.project.id, file).match(/ARG /)
          rescue StandardError
            STDERR.puts "Error reading file #{file} for project #{p.project.id}"
          end,
      }
    end
    .select { |p| p[:files].length > 0 }
end

def main()
  options = {
    hostname: ENV['hostname'],
    gitlab_access_token: ENV['gitlab_access_token'],
    bust_cache: false,
    search_term: '',
  }
  args =
    OptionParser
      .new do |opts|
        opts.banner = "Usage:\t#{$0} [OPTIONS] <SEARCH_TERM>"

        opts.on('--hostname HOSTNAME', 'Gitlab server hostname') do |p|
          options[:hostname] = p
        end

        opts.on('-p', '--pull-image', 'Pull the image from the registry') do |p|
          options[:pull_image] = p
        end

        opts.on(
          '--pat PERSONAL_ACCESS_TOKEN',
          'Gitlab Personal Access Token',
        ) { |p| options[:gitlab_access_token] = p }

        opts.on(
          '-b',
          '--bust-cache',
          'Overwrite any existing cached files',
        ) { |p| options[:bust_cache] = p }

        opts.on('-h', '--help', 'Prints this help') do
          puts opts
          exit 0
        end
      end
      .parse!
  options[:search_term] = args.pop

  configure_gitlab(options[:hostname], options[:gitlab_access_token])

  tmp_dir = "/tmp/io.orleans.gitlab-search/#{options[:hostname]}"
  FileUtils.mkdir_p tmp_dir unless Dir.exists? tmp_dir

  projects = get_relevant_projects(tmp_dir, options[:bust_cache])
  STDERR.puts "Found #{projects.length} projects."
  project_files = find_files(projects, tmp_dir, options[:bust_cache])
  STDERR.puts "Found #{project_files.length} projects with *erfiles"
  potential_projects = find_content_in_files(project_files)

  puts "# There are #{potential_projects.length} projects to check out:"
  puts ''
  potential_projects.each do |p|
    puts "- [ ] #{p[:project].homepage}/-/blob/master/Dockerfile"
  end
end

main
