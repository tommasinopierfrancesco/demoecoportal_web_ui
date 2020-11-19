
class AdminController < ApplicationController
  layout :determine_layout
  before_action :cache_setup

  DEBUG_BLACKLIST = [:"$,", :$ADDITIONAL_ONTOLOGY_DETAILS, :$rdebug_state, :$PROGRAM_NAME, :$LOADED_FEATURES, :$KCODE, :$-i, :$rails_rake_task, :$$, :$gems_build_rake_task, :$daemons_stop_proc, :$VERBOSE, :$DAEMONS_ARGV, :$daemons_sigterm, :$DEBUG_BEFORE, :$stdout, :$-0, :$-l, :$-I, :$DEBUG, :$', :$gems_rake_task, :$_, :$CODERAY_DEBUG, :$-F, :$", :$0, :$=, :$FILENAME, :$?, :$!, :$rdebug_in_irb, :$-K, :$TESTING, :$fileutils_rb_have_lchmod, :$EMAIL_EXCEPTIONS, :$binding, :$-v, :$>, :$SAFE, :$/, :$fileutils_rb_have_lchown, :$-p, :$-W, :$:, :$__dbg_interface, :$stderr, :$\, :$&, :$<, :$debug, :$;, :$~, :$-a, :$DEBUG_RDOC, :$CGI_ENV, :$LOAD_PATH, :$-d, :$*, :$., :$-w, :$+, :$@, :$`, :$stdin, :$1, :$2, :$3, :$4, :$5, :$6, :$7, :$8, :$9]
  ADMIN_URL = "#{LinkedData::Client.settings.rest_url}/admin/"
  ONTOLOGIES_URL = "#{ADMIN_URL}ontologies_report"
  ONTOLOGY_URL = lambda { |acronym| "#{ADMIN_URL}ontologies/#{acronym}" }
  PARSE_LOG_URL = lambda { |acronym| "#{ONTOLOGY_URL.call(acronym)}/log" }
  REPORT_NEVER_GENERATED = "NEVER GENERATED"

  def index
    if session[:user].nil? || !session[:user].admin?
      redirect_to :controller => 'login', :action => 'index', :redirect => '/admin'
    else
      render action: "index"
    end
  end

  def update_info
    response = {update_info: Hash.new, errors: '', success: '', notices: ''}
    json = LinkedData::Client::HTTP.get("#{ADMIN_URL}update_info", params, raw: true)

    begin
      update_info = JSON.parse(json)

      if update_info["error"]
        response[:errors] = update_info["error"]
      else
        response[:update_info] = update_info
        response[:notices] = update_info["notes"] if update_info["notes"]
        response[:success] = "Update info successfully retrieved"
      end
    rescue Exception => e
      response[:errors] = "Problem retrieving update info - #{e.message}"
    end
    render :json => response
  end

  def update_check_enabled
    enabled = LinkedData::Client::HTTP.get("#{ADMIN_URL}update_check_enabled", {}, raw: false)
    render :json => enabled
  end

  def submissions
    @submissions = nil
    @acronym = params["acronym"]
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(params["acronym"]).first
    begin
      submissions = @ontology.explore.submissions
      @submissions = submissions.sort {|a,b| b.submissionId <=> a.submissionId }
    rescue
      @submissions = []
    end
    render :partial => "layouts/ontology_report_submissions"
  end

  def parse_log
    @acronym = params["acronym"]
    @parse_log = LinkedData::Client::HTTP.get(PARSE_LOG_URL.call(params["acronym"]), {}, raw: false)
    ontologies_report = _ontologies_report
    ontology = ontologies_report[:ontologies][params["acronym"].to_sym]
    @log_file_path = ''

    if ontology
      full_log_file_path = ontology[:logFilePath]
      @log_file_path = /#{params["acronym"]}\/\d+\/[-a-zA-Z0-9_]+\.log$/.match(full_log_file_path)
    else
      @parse_log = "No record exists for ontology #{params["acronym"]}"
      @log_file_path = "None"
    end
    render action: "parse_log"
  end

  def clearcache
    response = {errors: '', success: ''}

    if @cache.respond_to?(:flush_all)
      begin
        @cache.flush_all
        response[:success] = "UI cache successfully flushed"
      rescue Exception => e
        response[:errors] = "Problem flushing the UI cache - #{e.class}: #{e.message}"
      end
    else
      response[:errors] = "The UI cache does not respond to the 'flush_all' command"
    end
    render :json => response
  end

  def resetcache
    response = {errors: '', success: ''}

    if @cache.respond_to?(:reset)
      begin
        @cache.reset
        response[:success] = "UI cache connection successfully reset"
      rescue Exception => e
        response[:errors] = "Problem resetting the UI cache connection - #{e.message}"
      end
    else
      response[:errors] = "The UI cache does not respond to the 'reset' command"
    end
    render :json => response
  end

  def clear_goo_cache
    response = {errors: '', success: ''}

    begin
      response_raw = LinkedData::Client::HTTP.post("#{ADMIN_URL}clear_goo_cache", params, raw: true)
      response[:success] = "Goo cache successfully flushed"
    rescue Exception => e
      response[:errors] = "Problem flushing the Goo cache - #{e.class}: #{e.message}"
    end
    render :json => response
  end

  def clear_http_cache
    response = {errors: '', success: ''}

    begin
      response_raw = LinkedData::Client::HTTP.post("#{ADMIN_URL}clear_http_cache", params, raw: true)
      response[:success] = "HTTP cache successfully flushed"
    rescue Exception => e
      response[:errors] = "Problem flushing the HTTP cache - #{e.class}: #{e.message}"
    end
    render :json => response
  end

  def ontologies_report
    response = _ontologies_report
    render :json => response
  end

  def refresh_ontologies_report
    response = {errors: '', success: ''}

    begin
      response_raw = LinkedData::Client::HTTP.post(ONTOLOGIES_URL, params, raw: true)
      response_json = JSON.parse(response_raw, :symbolize_names => true)

      if response_json[:errors]
        _process_errors(response_json[:errors], response, true)
      else
        response = response_json

        if params["ontologies"].nil? || params["ontologies"].empty?
          response[:success] = "Refresh of ontologies report started successfully";
        else
          ontologies = params["ontologies"].split(",").map {|o| o.strip}
          response[:success] = "Refresh of report for ontologies: #{ontologies.join(", ")} started successfully";
        end
      end
    rescue Exception => e
      response[:errors] = "Problem refreshing report - #{e.class}: #{e.message}"
      # puts "#{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}"
    end
    render :json => response
  end

  def process_ontologies
    _process_ontologies('enqued for processing', 'processing', :_process_ontology)
  end

  def delete_ontologies
    _process_ontologies('and all its artifacts deleted', 'deleting', :_delete_ontology)
  end

  def delete_submission
    response = {errors: '', success: ''}

    begin
      ont = params["acronym"]
      ontology = LinkedData::Client::Models::Ontology.find_by_acronym(ont).first

      if ontology
        submissions = ontology.explore.submissions
        submission = submissions.select {|o| o.submissionId == params["id"].to_i}.first

        if submission
          error_response = submission.delete

          if error_response
            errors = response_errors(error_response) # see application_controller::response_errors
            _process_errors(errors, response, true)
          else
            response[:success] << "Submission #{params["id"]} for ontology #{ont} was deleted successfully"
          end
        else
          response[:errors] << "Submission #{params["id"]} for ontology #{ont} was not found in the system"
        end
      else
        response[:errors] << "Ontology #{ont} was not found in the system"
      end
    rescue Exception => e
      response[:errors] << "Problem deleting submission #{params["id"]} for ontology #{ont} - #{e.class}: #{e.message}"
    end
    render :json => response
  end

  private

  def cache_setup
    @cache = Rails.cache.instance_variable_get("@data")
  end

  def _ontologies_report
    response = {ontologies: Hash.new, report_date_generated: REPORT_NEVER_GENERATED, errors: '', success: ''}
    start = Time.now

    begin
      ontologies_data = LinkedData::Client::HTTP.get(ONTOLOGIES_URL, {}, raw: true)
      ontologies_data_parsed = JSON.parse(ontologies_data, :symbolize_names => true)

      if ontologies_data_parsed[:errors]
        _process_errors(ontologies_data_parsed[:errors], response, true)
      else
        response.merge!(ontologies_data_parsed)
        response[:success] = "Report successfully regenerated on #{ontologies_data_parsed[:report_date_generated]}"
        LOG.add :debug, "Ontologies Report - retrieved #{response[:ontologies].length} ontologies in #{Time.now - start}s"
      end
    rescue Exception => e
      response[:errors] = "Problem retrieving ontologies report - #{e.message}"
    end
    response
  end

  def _process_errors(errors, response, remove_trailing_comma=true)
    if errors.is_a?(Hash)
      errors.each do |_, v|
        if v.kind_of?(Array)
          response[:errors] << v.join(", ")
          response[:errors] << ", "
        else
          response[:errors] << "#{v}, "
        end
      end
    elsif errors.kind_of?(Array)
      errors.each {|err| response[:errors] << "#{err}, "}
    end
    response[:errors] = response[:errors][0...-2] if remove_trailing_comma
  end

  def _delete_ontology(ontology, params)
    error_response = ontology.delete
    error_response
  end

  def _process_ontology(ontology, params)
    error_response = LinkedData::Client::HTTP.put(ONTOLOGY_URL.call(ontology.acronym), params)
    error_response
  end

  def _process_ontologies(success_keyword, error_keyword, process_proc)
    response = {errors: '', success: ''}

    if params["ontologies"].nil? || params["ontologies"].empty?
      response[:errors] = "No ontologies parameter passed. Syntax: ?ontologies=ONT1,ONT2,...,ONTN"
    else
      ontologies = params["ontologies"].split(",").map {|o| o.strip}

      ontologies.each do |ont|
        begin
          ontology = LinkedData::Client::Models::Ontology.find_by_acronym(ont).first

          if ontology
            error_response = self.send(process_proc, ontology, params)

            if error_response
              errors = response_errors(error_response) # see application_controller::response_errors
              _process_errors(errors, response, false)
            else
              response[:success] << "Ontology #{ont} #{success_keyword} successfully, "
            end
          else
            response[:errors] << "Ontology #{ont} was not found in the system, "
          end
        rescue Exception => e
          response[:errors] << "Problem #{error_keyword} ontology #{ont} - #{e.class}: #{e.message}, "
        end
      end
      response[:success] = response[:success][0...-2] unless response[:success].empty?
      response[:errors] = response[:errors][0...-2] unless response[:errors].empty?
    end
    render :json => response
  end

end
