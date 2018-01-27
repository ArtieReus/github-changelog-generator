# frozen_string_literal: true

require "github_changelog_generator/octo_fetcher"
require "github_changelog_generator/generator/generator_fetcher"
require "github_changelog_generator/generator/generator_processor"
require "github_changelog_generator/generator/generator_tags"
require "github_changelog_generator/generator/entry"
require "github_changelog_generator/generator/section"

module GitHubChangelogGenerator
  # Default error for ChangelogGenerator
  class ChangelogGeneratorError < StandardError
  end

  # This class is the high-level code for gathering issues and PRs for a github
  # repository and generating a CHANGELOG.md file. A changelog is made up of a
  # series of "entries" of all tagged releases, plus an extra entry for the
  # unreleased changes. Entries are made up of various organizational
  # "sections," and sections contain the github issues and PRs.
  #
  # So the changelog contains entries, entries contain sections, and sections
  # contain issues and PRs.
  #
  # @see GitHubChangelogGenerator::Entry
  # @see GitHubChangelogGenerator::Section
  class Generator
    attr_accessor :options, :filtered_tags, :tag_section_mapping, :sorted_tags

    # A Generator responsible for all logic, related with changelog generation from ready-to-parse issues
    #
    # Example:
    #   generator = GitHubChangelogGenerator::Generator.new
    #   content = generator.compound_changelog
    def initialize(options = {})
      @options        = options
      @tag_times_hash = {}
      @fetcher        = GitHubChangelogGenerator::OctoFetcher.new(options)
      @sections       = []
    end

    # Main function to start changelog generation
    #
    # @return [String] Generated changelog file
    def compound_changelog
      options.load_custom_ruby_files
      fetch_and_filter_tags
      fetch_issues_and_pr

      log = ""
      log += options[:frontmatter] if options[:frontmatter]
      log += "#{options[:header]}\n\n"

      log += if options[:unreleased_only]
               generate_entry_between_tags(filtered_tags[0], nil)
             else
               generate_entries_for_all_tags
             end

      log += File.read(options[:base]) if File.file?(options[:base])

      credit_line = "\n\n\\* *This Changelog was automatically generated by [github_changelog_generator](https://github.com/skywinder/Github-Changelog-Generator)*"
      log.gsub!(credit_line, "") # Remove old credit lines
      log += credit_line

      @log = log
    end

    private

    # Generate log only between 2 specified tags
    # @param [String] older_tag all issues before this tag date will be excluded. May be nil, if it's first tag
    # @param [String] newer_tag all issue after this tag will be excluded. May be nil for unreleased section
    def generate_entry_between_tags(older_tag, newer_tag)
      filtered_issues, filtered_pull_requests = filter_issues_for_tags(newer_tag, older_tag)

      if newer_tag.nil? && filtered_issues.empty? && filtered_pull_requests.empty?
        # do not generate empty unreleased section
        return ""
      end

      newer_tag_link, newer_tag_name, newer_tag_time = detect_link_tag_time(newer_tag)

      # If the older tag is nil, go back in time from the latest tag and find
      # the SHA for the first commit.
      older_tag_name =
        if older_tag.nil?
          @fetcher.commits_before(newer_tag_time).last["sha"]
        else
          older_tag["name"]
        end

      Entry.new(options).generate_entry_for_tag(filtered_pull_requests, filtered_issues, newer_tag_name, newer_tag_link, newer_tag_time, older_tag_name)
    end

    # Filters issues and pull requests based on, respectively, `closed_at` and `merged_at`
    #  timestamp fields.
    #
    # @return [Array] filtered issues and pull requests
    def filter_issues_for_tags(newer_tag, older_tag)
      filtered_pull_requests = delete_by_time(@pull_requests, "merged_at", older_tag, newer_tag)
      filtered_issues        = delete_by_time(@issues, "closed_at", older_tag, newer_tag)

      newer_tag_name = newer_tag.nil? ? nil : newer_tag["name"]

      if options[:filter_issues_by_milestone]
        # delete excess irrelevant issues (according milestones). Issue #22.
        filtered_issues = filter_by_milestone(filtered_issues, newer_tag_name, @issues)
        filtered_pull_requests = filter_by_milestone(filtered_pull_requests, newer_tag_name, @pull_requests)
      end
      [filtered_issues, filtered_pull_requests]
    end

    # The full cycle of generation for whole project
    # @return [String] All entries in the changelog
    def generate_entries_for_all_tags
      puts "Generating entry..." if options[:verbose]

      entries = generate_unreleased_entry

      @tag_section_mapping.each_pair do |_tag_section, left_right_tags|
        older_tag, newer_tag = left_right_tags
        entries += generate_entry_between_tags(older_tag, newer_tag)
      end

      entries
    end

    def generate_unreleased_entry
      entry = ""
      if options[:unreleased]
        start_tag        = filtered_tags[0] || sorted_tags.last
        unreleased_entry = generate_entry_between_tags(start_tag, nil)
        entry           += unreleased_entry if unreleased_entry
      end
      entry
    end

    def fetch_issues_and_pr
      issues, pull_requests = @fetcher.fetch_closed_issues_and_pr

      @pull_requests = options[:pulls] ? get_filtered_pull_requests(pull_requests) : []

      @issues = options[:issues] ? get_filtered_issues(issues) : []

      fetch_events_for_issues_and_pr
      detect_actual_closed_dates(@issues + @pull_requests)
    end
  end
end
