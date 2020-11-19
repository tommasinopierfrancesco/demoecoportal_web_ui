require 'json'
require 'cgi'

class AnnotatorplusController < ApplicationController
  layout :determine_layout

  # REST_URI is defined in application_controller.rb
  ANNOTATOR_URI = PROXY_URI + "/annotatorplus/"

  def index
    @semantic_types_for_select = []
    @semantic_types ||= get_semantic_types
    @sem_type_ont = LinkedData::Client::Models::Ontology.find_by_acronym('STY').first
    @semantic_groups ||= {"ACTI" => "Activities & Behaviors", "ANAT" => "Anatomy", "CHEM" => "Chemicals & Drugs","CONC" => "Concepts & Ideas",
                          "DEVI" => "Devices", "DISO" => "Disorders", "GENE" => "Genes & Molecular Sequences", "GEOG" => "Geographic Areas", "LIVB" => "Living Beings",
                          "OBJC" => "Objects", "OCCU" => "Occupations", "ORGA" => "Organizations", "PHEN" => "Phenomena", "PHYS" => "Physiology","PROC" => "Procedures"}
    @semantic_groups_for_select = []
    @semantic_types.each_pair do |code, label|
      @semantic_types_for_select << ["#{label} (#{code})", code]
    end
     @semantic_groups.each_pair do |group, label|
      @semantic_groups_for_select << ["#{label} (#{group})", group]
    end

    @semantic_types_for_select.sort! {|a,b| a[0] <=> b[0]}
    @semantic_groups_for_select.sort! {|a,b| a[0] <=> b[0]}
    @recognizers = parse_json(REST_URI + "/annotator/recognizers")
    @annotator_ontologies = LinkedData::Client::Models::Ontology.all
    @annotator_ontologies.sort_by! { |ont| ont.name.strip.downcase }
  end


  def create
    params[:mappings] ||= []
    params[:max_level] ||= 0
    params[:ontologies] ||= []
    params[:semantic_types] ||= []
    params[:semantic_groups] ||= []
    text_to_annotate = params[:text].strip.gsub("\r\n", " ").gsub("\n", " ")

    options = { :ontologies => params[:ontologies],
                :class_hierarchy_max_level => params[:class_hierarchy_max_level].to_i,
                :expand_class_hierarchy => params[:class_hierarchy_max_level].to_i > 0,
                :semantic_types => params[:semantic_types],
                :semantic_groups => params[:semantic_groups],
                :mappings => params[:mappings],
                :longest_only => params[:longest_only],
                :exclude_numbers => params[:exclude_numbers] ||= "false",  # service default is false
                :whole_word_only => (params[:whole_word_only] == "true") ? "false" : "true",  # service default is true
                :exclude_synonyms => params[:exclude_synonyms] ||= "false",  # service default is false
                :negation => params[:negation] ||= "false",  # service default is false
                :experiencer => params[:experiencer] ||= "false",  # service default is false
                :temporality => params[:temporality] ||= "false",  # service default is false
                :score => params[:score],
                :score_threshold => params[:score_threshold] ||=-1,
                :confidence_threshold => params[:confidence_threshold] ||=-1,
                :ncbo_slice => params[:ncbo_slice] || ''
    }

    start = Time.now
    query = ANNOTATOR_URI
    query += "?text=" + CGI.escape(text_to_annotate)
    query += "&include=prefLabel"
    query += "&expand_class_hierarchy=true" if options[:class_hierarchy_max_level] > 0
    query += "&class_hierarchy_max_level=" + options[:class_hierarchy_max_level].to_s if options[:class_hierarchy_max_level] > 0
        query += "&score=" + options[:score] unless options[:score] == ""
    query += "&score_threshold=" + options[:score_threshold] unless options[:score] == "" or options[:score_threshold]==-1
    query += "&confidence_threshold=" + options[:confidence_threshold] unless options[:score] == "" or options[:confidence_threshold]==-1
    query += "&negation=" + options[:negation] unless options[:negation].empty?
    query += "&experiencer=" + options[:experiencer] unless options[:experiencer].empty?
    query += "&temporality=" + options[:temporality] unless options[:temporality].empty?
    query += "&ontologies=" + CGI.escape(options[:ontologies].join(',')) unless options[:ontologies].empty?
    query += "&semantic_types=" + options[:semantic_types].join(',') unless options[:semantic_types].empty?
    query += "&semantic_groups=" + options[:semantic_groups].join(',') unless options[:semantic_groups].empty?
    query += "&mappings=" + options[:mappings].join(',') unless options[:mappings].empty?
    query += "&longest_only=#{options[:longest_only]}"
    query += "&recognizer=#{params[:recognizer]}"
    query += "&exclude_numbers=" + options[:exclude_numbers].to_s unless options[:exclude_numbers].empty?
    query += "&whole_word_only=" + options[:whole_word_only].to_s unless options[:whole_word_only].empty?
    query += "&exclude_synonyms=" + options[:exclude_synonyms].to_s unless options[:exclude_synonyms].empty?
    query += "&ncbo_slice=" + options[:ncbo_slice].to_s unless options[:ncbo_slice].empty?

    annotations = parse_json(query) # See application_controller.rb
    #annotations = LinkedData::Client::HTTP.get(query)
    LOG.add :debug, "Retrieved #{annotations.length} annotations: #{Time.now - start}s"
    if annotations.empty? || params[:raw] == "true"
      # TODO: if params contains select ontologies and/or semantic types, only return those selected.
      response = {
          annotations: annotations,
          ontologies: get_simplified_ontologies_hash,  # application_controller
          semantic_types: get_semantic_types           # application_controller
      }
    else
      massage_annotated_classes(annotations, options)
      response = {
          annotations: annotations,
          ontologies: {},        # ontology data are in annotations already.
          semantic_types: {}     # semantic types are in annotations already.
      }
    end

    render :json => response
  end

  private

  def get_semantic_types
    semantic_types = {}
    sty_ont = LinkedData::Client::Models::Ontology.find_by_acronym('STY').first
    return semantic_types if sty_ont.nil?
    # The first 500 items should be more than sufficient to get all semantic types.
    sty_classes = sty_ont.explore.classes({'pagesize'=>500, include: 'prefLabel'})
    sty_classes.collection.each do |cls|
      code = cls.id.split("/").last
      semantic_types[ code ] = cls.prefLabel
    end
    semantic_types
  end

  def massage_annotated_classes(annotations, options)
    # Get the class details required for display, assume this is necessary
    # for every element of the annotations array because the API returns a set.
    # Use the batch REST API to get all the annotated class prefLabels.
    start = Time.now
    semantic_types = options[:semantic_types] || []
    class_details = get_annotated_classes(annotations, semantic_types)
    simplify_annotated_classes(annotations, class_details)
    # repeat the simplification for any annotation hierarchy or mappings.
    hierarchy = annotations.map {|a| a if a.keys.include? 'hierarchy' }.compact
    hierarchy.each do |a|
      simplify_annotated_classes(a['hierarchy'], class_details) if not a['hierarchy'].empty?
    end
    mappings = annotations.map {|a| a if a.keys.include? 'mappings' }.compact
    mappings.each do |a|
      simplify_annotated_classes(a['mappings'], class_details) if not a['mappings'].empty?
    end
    LOG.add :debug, "Completed massage for annotated classes: #{Time.now - start}s"
  end

  def simplify_annotated_classes(annotations, class_details)
    annotations2delete = []
    annotations.each do |a|
      cls_id = a['annotatedClass']['@id']
      details = class_details[cls_id]
      if details.nil?
        LOG.add :debug, "Failed to get class details for: #{a['annotatedClass']['links']['self']}"
        annotations2delete.push(cls_id)
      else
        # Replace the annotated class with simplified details.
        a['annotatedClass'] = details
      end
    end
    # Remove any annotations that fail to resolve details.
    annotations.delete_if { |a| annotations2delete.include? a['annotatedClass']['@id'] }
  end

  def get_annotated_class_hash(a)
    return {
        :class => a['annotatedClass']['@id'],
        :ontology => a['annotatedClass']['links']['ontology']
    }
  end

  def get_annotated_classes(annotations, semantic_types=[])
    # Use batch service to get class prefLabels
    class_list = []
    annotations.each {|a| class_list << get_annotated_class_hash(a) }
    hierarchy = annotations.map {|a| a if a.keys.include? 'hierarchy' }.compact
    hierarchy.each do |a|
      a['hierarchy'].each {|h| class_list << get_annotated_class_hash(h) }
    end
    mappings = annotations.map {|a| a if a.keys.include? 'mappings' }.compact
    mappings.each do |a|
      a['mappings'].each {|m| class_list << get_annotated_class_hash(m) }
    end
    classes_simple = {}
    return classes_simple if class_list.empty?
    # remove duplicates
    class_set = class_list.to_set # get unique class:ontology set
    class_list = class_set.to_a   # collection requires a list in batch call
    # make the batch call
    properties = 'prefLabel'
    properties = 'prefLabel,semanticType' if not semantic_types.empty?
    call_params = {'http://www.w3.org/2002/07/owl#Class'=>{'collection'=>class_list, 'include'=>properties}}
    classes_json = get_batch_results(call_params)
    # Simplify the response data for the UI
    @ontologies_hash ||= get_simplified_ontologies_hash # application_controller
    classes_data = JSON.parse(classes_json)
    classes_data["http://www.w3.org/2002/07/owl#Class"].each do |cls|
      c = simplify_class_model(cls)
      ont_details = @ontologies_hash[ c[:ontology] ]
      next if ont_details.nil? # NO DISPLAY FOR ANNOTATIONS ON ANY CLASS OUTSIDE THE BIOPORTAL ONTOLOGY SET.
      c[:ontology] = ont_details
      unless semantic_types.empty? || cls['semanticType'].nil?
        @semantic_types ||= get_semantic_types   # application_controller
        # Extract the semantic type descriptions that are requested.
        semanticTypeURI = 'http://bioportal.bioontology.org/ontologies/umls/sty/'
        semanticCodes = cls['semanticType'].map {|t| t.sub( semanticTypeURI, '') }
        requestedCodes = semanticCodes.map {|code| (semantic_types.include? code and code) || nil }.compact
        requestedDescriptions = requestedCodes.map {|code| @semantic_types[code] }.compact
        c[:semantic_types] = requestedDescriptions
      else
        c[:semantic_types] = []
      end
      classes_simple[c[:id]] = c
    end
    return classes_simple
  end

end
