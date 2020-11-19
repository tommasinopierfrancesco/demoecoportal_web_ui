class OntologiesController < ApplicationController
  include MappingsHelper

  require "multi_json"
  require 'cgi'

  helper :concepts
  layout :determine_layout

  before_action :authorize_and_redirect, :only=>[:edit,:update,:create,:new]

  KNOWN_PAGES = Set.new(["terms", "classes", "mappings", "notes", "widgets", "summary", "properties"])

  # GET /ontologies
  # GET /ontologies.xml
  def index_old
    @ontologies = LinkedData::Client::Models::Ontology.all(include: LinkedData::Client::Models::Ontology.include_params)
    @submissions = LinkedData::Client::Models::OntologySubmission.all
    @submissions_map = Hash[@submissions.map {|sub| [sub.ontology.acronym, sub] }]
    @categories = LinkedData::Client::Models::Category.all
    @groups = LinkedData::Client::Models::Group.all

    # Count the number of classes in each ontology
    metrics_hash = get_metrics_hash
    @class_counts = {}
    @ontologies.each do |o|
      @class_counts[o.id] = metrics_hash[o.id].classes if metrics_hash[o.id]
      @class_counts[o.id] ||= 0
    end

    @mapping_counts = {}
    @note_counts = {}
    respond_to do |format|
      format.html # index.rhtml
    end
  end

  include ActionView::Helpers::NumberHelper
  include OntologiesHelper
  def index
    @app_name = "FacetedBrowsing"
    @app_dir = "/browse"
    @base_path = @app_dir
    ontologies = LinkedData::Client::Models::Ontology.all(include: LinkedData::Client::Models::Ontology.include_params + ",viewOf", include_views: true, display_context: false)
    ontologies_hash = Hash[ontologies.map {|o| [o.id, o] }]
    @admin = session[:user] ? session[:user].admin? : false
    @development = Rails.env.development?

    submissions = LinkedData::Client::Models::OntologySubmission.all(include_views: true, display_links: false, display_context: false)
    submissions_map = Hash[submissions.map {|sub| [sub.ontology.acronym, sub] }]

    @categories = LinkedData::Client::Models::Category.all(display_links: false, display_context: false)
    @categories_hash = Hash[@categories.map {|c| [c.id, c] }]

    @groups = LinkedData::Client::Models::Group.all(display_links: false, display_context: false)
    @groups_hash = Hash[@groups.map {|g| [g.id, g] }]

    analytics = LinkedData::Client::Analytics.last_month
    @analytics = Hash[analytics.onts.map {|o| [o[:ont].to_s, o[:views]]}]

    reviews = {}
    LinkedData::Client::Models::Review.all(display_links: false, display_context: false).each do |r|
      reviews[r.reviewedOntology] ||= []
      reviews[r.reviewedOntology] << r
    end

    metrics_hash = get_metrics_hash

    @formats = Set.new

    @ontologies = []
    ontologies.each do |ont|
      o = {}

      if metrics_hash[ont.id]
        o[:class_count] = metrics_hash[ont.id].classes
        o[:individual_count] = metrics_hash[ont.id].individuals
      else
        o[:class_count] = 0
        o[:individual_count] = 0
      end
      o[:class_count_formatted] = number_with_delimiter(o[:class_count], :delimiter => ",")
      o[:individual_count_formatted] = number_with_delimiter(o[:individual_count], :delimiter => ",")

      o[:id]               = ont.id
      o[:type]             = ont.viewOf.nil? ? "ontology" : "ontology_view"
      o[:show]             = ont.viewOf.nil? ? true : false # show ontologies only by default
      o[:reviews]          = reviews[ont.id] || []
      o[:groups]           = ont.group || []
      o[:categories]       = ont.hasDomain || []
      o[:note_count]       = ont.notes.length
      o[:review_count]     = ont.reviews.length
      o[:project_count]    = ont.projects.length
      o[:private]          = ont.private?
      o[:popularity]       = @analytics[ont.acronym] || 0
      o[:submissionStatus] = []
      o[:administeredBy]   = ont.administeredBy
      o[:name]             = ont.name
      o[:acronym]          = ont.acronym
      o[:projects]         = ont.projects
      o[:notes]            = ont.notes

      o[:viewOfOnt] = {
        name: ontologies_hash[ont.viewOf].name,
        acronym: ontologies_hash[ont.viewOf].acronym
      } if o[:type].eql?("ontology_view")

      o[:artifacts] = []
      o[:artifacts] << "notes" if ont.notes.length > 0
      o[:artifacts] << "reviews" if ont.reviews.length > 0
      o[:artifacts] << "projects" if ont.projects.length > 0
      o[:artifacts] << "summary_only" if ont.summaryOnly

      sub = submissions_map[ont.acronym]
      if sub
        o[:submissionStatus]          = sub.submissionStatus
        o[:submission]                = true
        o[:pullLocation]              = sub.pullLocation
        o[:description]               = sub.description
        o[:creationDate]              = sub.creationDate
        o[:submissionStatusFormatted] = submission_status2string(sub).gsub(/\(|\)/, "")

        o[:format] = sub.hasOntologyLanguage
        @formats << sub.hasOntologyLanguage
      else
        # Used to sort ontologies without subnissions to the end when sorting on upload date
        o[:creationDate] = DateTime.parse("19900601")
      end

      @ontologies << o
    end

    @ontologies.sort! {|a,b| b[:popularity] <=> a[:popularity]}

    render 'browse'
  end

  def classes
    get_class(params)

    if ["application/ld+json", "application/json"].include?(request.accept)
      render plain: @concept.to_jsonld, content_type: request.accept and return
    end

    @current_purl = @concept.purl if $PURL_ENABLED
    @submission = get_ontology_submission_ready(@ontology)

    unless @concept.id == "bp_fake_root"
      @notes = @concept.explore.notes
      @mappings = get_concept_mappings(@concept)
      @delete_mapping_permission = check_delete_mapping_permission(@mappings)
    end
    
    update_tab(@ontology, @concept.id)

    if request.xhr?
      render "visualize", layout: false
    else
      render "visualize", layout: "ontology_viewer"
    end
  end

  def properties
    if request.xhr?
      return render 'properties', :layout => false
    else
      return render 'properties', :layout => "ontology_viewer"
    end
  end

  def create
    if params['commit'] == 'Cancel'
      redirect_to "/ontologies"
      return
    end
    @ontology = LinkedData::Client::Models::Ontology.new(values: ontology_params)
    @ontology_saved = @ontology.save
    if !@ontology_saved || @ontology_saved.errors
      @categories = LinkedData::Client::Models::Category.all
      @user_select_list = LinkedData::Client::Models::User.all.map {|u| [u.username, u.id]}
      @user_select_list.sort! {|a,b| a[1].downcase <=> b[1].downcase}
      @errors = response_errors(@ontology_saved)
      #@errors = {acronym: "Acronym already exists, please use another"} if @ontology_saved.status == 409
      render "new"
    else
      # TODO_REV: Enable subscriptions
      # if params["ontology"]["subscribe_notifications"].eql?("1")
      #  DataAccess.createUserSubscriptions(@ontology.administeredBy, @ontology.ontologyId, NOTIFICATION_TYPES[:all])
      # end
      if @ontology_saved.summaryOnly
        redirect_to "/ontologies/success/#{@ontology.acronym}"
      else
        redirect_to new_ontology_submission_url(ontology_id: @ontology.acronym)
      end
    end
  end

  def edit
    # Note: find_by_acronym includes ontology views
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(params[:id]).first
    redirect_to_home unless session[:user] && @ontology.administeredBy.include?(session[:user].id) || session[:user].admin?
    @categories = LinkedData::Client::Models::Category.all
    @user_select_list = LinkedData::Client::Models::User.all.map {|u| [u.username, u.id]}
    @user_select_list.sort! {|a,b| a[1].downcase <=> b[1].downcase}
  end

  def mappings
    counts = LinkedData::Client::HTTP.get("#{LinkedData::Client.settings.rest_url}/mappings/statistics/ontologies/#{params[:id]}")
    @ontologies_mapping_count = []
    unless counts.nil?
      counts.members.each do |acronym|
        count = counts[acronym]
        # Note: find_by_acronym includes ontology views
        ontology = LinkedData::Client::Models::Ontology.find_by_acronym(acronym.to_s).first
        next unless ontology
        @ontologies_mapping_count << {'ontology' => ontology, 'count' => count}
      end
      @ontologies_mapping_count.sort! {|a,b| a['ontology'].name.downcase <=> b['ontology'].name.downcase } unless @ontologies_mapping_count.nil? || @ontologies_mapping_count.length == 0
    end
    @ontology_id = @ontology.acronym
    @ontology_label = @ontology.name
    if request.xhr?
      render :partial => 'mappings', :layout => false
    else
      render :partial => 'mappings', :layout => "ontology_viewer"
    end
  end

  def new
    @ontology = LinkedData::Client::Models::Ontology.new
    @ontologies =  LinkedData::Client::Models::Ontology.all(include: "acronym", include_views: true, display_links: false, display_context: false)
    @categories = LinkedData::Client::Models::Category.all
    @user_select_list = LinkedData::Client::Models::User.all.map {|u| [u.username, u.id]}
    @user_select_list.sort! {|a,b| a[1].downcase <=> b[1].downcase}
  end

  def notes
    # Get the latest 'ready' submission, or fallback to any latest submission
    @submission = get_ontology_submission_ready(@ontology)  # application_controller
    @notes = @ontology.explore.notes
    @notes_deletable = false
    # TODO_REV: Handle notes deletion
    # @notes.each {|n| @notes_deletable = true if n.deletable?(session[:user])} if @notes.kind_of?(Array)
    @note_link = "/ontologies/#{@ontology.acronym}/notes/"
    if request.xhr?
      render :partial => 'notes', :layout => false
    else
      render :partial => 'notes', :layout => "ontology_viewer"
    end
  end

  # GET /ontologies/1
  # GET /ontologies/1.xml
  def show
    # Hack to make ontologyid and conceptid work in addition to id and ontology params
    params[:id] = params[:id].nil? ? params[:ontologyid] : params[:id]
    params[:ontology] = params[:ontology].nil? ? params[:id] : params[:ontology]

    # PURL-specific redirect to handle /ontologies/{ACR}/{CLASS_ID} paths
    if params[:purl_conceptid]
      params[:purl_conceptid] = "root" if params[:purl_conceptid].eql?("classes")
      if params[:conceptid]
        params.delete(:purl_conceptid)
      else
        params[:conceptid] = params.delete(:purl_conceptid)
      end
      redirect_to "/ontologies/#{params[:acronym]}?p=classes#{params_string_for_redirect(params, prefix: "&")}", :status => :moved_permanently
      return
    end

    if params[:ontology].to_i > 0
      acronym = BPIDResolver.id_to_acronym(params[:ontology])
      if acronym
        redirect_new_api
        return
      end
    end

    # Note: find_by_acronym includes ontology views
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(params[:ontology]).first
    not_found if @ontology.nil?
    
    # Handle the case where an ontology is converted to summary only. 
    # See: https://github.com/ncbo/bioportal_web_ui/issues/133.
    if @ontology.summaryOnly && params[:p].present?
      pages = KNOWN_PAGES - ["summary", "notes"]
      if pages.include?(params[:p])
        redirect_to(ontology_path(params[:ontology]), status: :temporary_redirect) and return
      end
    end

    @ob_instructions = helpers.ontolobridge_instructions_template(@ontology)

    # Retrieve submissions in descending submissionId order (should be reverse chronological order)
    @submissions = @ontology.explore.submissions.sort {|a,b| b.submissionId.to_i <=> a.submissionId.to_i } || []
    LOG.add :error, "No submissions for ontology: #{@ontology.id}" if @submissions.empty?

    # Get the latest submission (not necessarily the latest 'ready' submission)
    @submission_latest = @ontology.explore.latest_submission rescue @ontology.explore.latest_submission(include: "")

    # Is the ontology downloadable?
    restrict_downloads = $NOT_DOWNLOADABLE
    @ont_restricted = restrict_downloads.include? @ontology.acronym

    # Fix parameters to only use known pages
    params[:p] = nil unless KNOWN_PAGES.include?(params[:p])

    # This action is now a router using the 'p' parameter as the page to show
    case params[:p]
      when "terms"
        params[:p] = 'classes'
        redirect_to "/ontologies/#{params[:ontology]}#{params_string_for_redirect(params)}", :status => :moved_permanently
        return
      when "classes"
        self.classes #rescue self.summary
        return
      when "mappings"
        self.mappings #rescue self.summary
        return
      when "notes"
        self.notes #rescue self.summary
        return
      when "widgets"
        self.widgets #rescue self.summary
        return
      when "properties"
        self.properties #rescue self.summary
        return
      when "summary"
        self.summary
        return
      else
        self.summary
        return
    end
  end

  def submit_success
    @acronym = params[:id]
    # Force the list of ontologies to be fresh by adding a param with current time
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(params[:id], cache_invalidate: Time.now.to_i).first
    render "submit_success"
  end

  def summary
    # Check to see if user is requesting RDF+XML. If so, return the file from the REST service.
    if request.accept.to_s.eql?("application/ld+json") || request.accept.to_s.eql?("application/json")
      headers['Content-Type'] = request.accept.to_s
      render plain: @ontology.to_jsonld
      return
    end
    
    @metrics = @ontology.explore.metrics rescue []
    @projects = @ontology.explore.projects.sort { |a,b| a.name.downcase <=> b.name.downcase } || []
    @analytics = LinkedData::Client::HTTP.get(@ontology.links["analytics"])
    @views = get_views(@ontology)
    @view_decorators = @views.map{ |view| ViewDecorator.new(view, view_context) }
    
    if request.xhr?
      render partial: "metadata", layout: false
    else
      render partial: "metadata", layout: "ontology_viewer"
    end
  end

  def update
    if params['commit'] == 'Cancel'
      acronym = params['id']
      redirect_to "/ontologies/#{acronym}"
      return
    end
    # Note: find_by_acronym includes ontology views
    @ontology = LinkedData::Client::Models::Ontology.find_by_acronym(params[:ontology][:acronym] || params[:id]).first
    @ontology.update_from_params(ontology_params)
    error_response = @ontology.update
    if error_response
      @categories = LinkedData::Client::Models::Category.all
      @user_select_list = LinkedData::Client::Models::User.all.map {|u| [u.username, u.id]}
      @user_select_list.sort! {|a,b| a[1].downcase <=> b[1].downcase}
      @errors = response_errors(error_response)
      @errors = {acronym: "Acronym already exists, please use another"} if error_response.status == 409
    else
      # TODO_REV: Enable subscriptions
      # if params["ontology"]["subscribe_notifications"].eql?("1")
      #  DataAccess.createUserSubscriptions(@ontology.administeredBy, @ontology.ontologyId, NOTIFICATION_TYPES[:all])
      # end
      redirect_to "/ontologies/#{@ontology.acronym}"
    end
  end

  def virtual
    redirect_new_api
  end

  def visualize
    redirect_new_api(true)
  end

  def widgets
    if request.xhr?
      render :partial => 'widgets', :layout => false
    else
      render :partial => 'widgets', :layout => "ontology_viewer"
    end
  end

  private

  def ontology_params
    p = params.require(:ontology).permit(:name, :acronym, { administeredBy:[] }, :viewingRestriction, { acl:[] },
                                         { hasDomain:[] }, :isView, :viewOf, :subscribe_notifications)

    p[:administeredBy].reject!(&:blank?)
    p[:acl].reject!(&:blank?)
    p[:hasDomain].reject!(&:blank?)
    p.to_h
  end

  def determine_layout
    case action_name
    when 'index'
      'angular'
    else
      super
    end
  end

  def get_views(ontology)
    views = ontology.explore.views || []
    views.select!{ |view| view.access?(session[:user]) }
    views.sort{ |a,b| a.acronym.downcase <=> b.acronym.downcase }
  end

end
