
"use strict";

// Note similar code in concepts_helper.rb mirrors the following code:
function bp_ont_link(ont_acronym){
  return "/ontologies/" + ont_acronym;
}
function bp_cls_link(cls_id, ont_acronym){
  return bp_ont_link(ont_acronym) + "?p=classes&conceptid=" + encodeURIComponent(cls_id);
}
function get_link_for_cls_ajax(cls_id, ont_acronym) {
  // ajax call will replace the class label using data attributes (triggered by class='cls4ajax')
  var data_cls = " data-cls='" + cls_id + "' ";
  var data_ont = " data-ont='" + ont_acronym + "' ";
  return "<a class='cls4ajax'" + data_cls + data_ont + "href='" + bp_cls_link(cls_id, ont_acronym) + "'>" + cls_id + "</a>";
}
function get_link_for_ont_ajax(ont_acronym) {
  var data_ont = " data-ont='" + ont_acronym + "' ";
  return "<a class='ont4ajax'" + data_ont + "href='" + bp_ont_link(ont_acronym) + "'>" + ont_acronym + "</a>";
}

var
  ajax_process_cls_interval = null,
  ajax_process_ont_interval = null,
  ajax_process_timeout = 20, // Timeout after 20 sec.
  ajax_process_timing = 250; // It takes about 250 msec to resolve a class ID to a prefLabel

var ajax_process_init = function () {
  ajax_process_cls_init();
  ajax_process_ont_init();
};
var ajax_process_halt = function () {
  ajax_process_cls_halt();
  ajax_process_ont_halt();
};


// **************************************************************************************
// ONTOLOGY NAMES

// Note: If we don't query every time, using the array should be faster; it
//       means the ajax_ont_init must be called after all the elements
//       are created because they will not be detected in a dynamic iteration.
var ajax_ont_array = [];
var ajax_process_ont_init = function() {
  ajax_ont_array = jQuery("a.ont4ajax").toArray();
  ajax_process_ont_interval = window.setInterval(ajax_process_ont, ajax_process_timing);
};
var ajax_process_ont_halt = function () {
  ajax_ont_array = [];
  window.clearInterval(ajax_process_ont_interval); // stop the ajax process
  // Note: might leave faulty href links, but it usually means moving on to entirely different content
  //       so it's not likely those links will be available for interaction.
  // clear all the classes and ontologies to be resolved by ajax
  //jQuery("a.ont4ajax").removeClass('ont4ajax');
  //jQuery("a.ajax-modified-ont").removeClass('ajax-modified-ont');
};
var ajax_process_ont = function() {
  if( ajax_ont_array.length === 0 ){
    ajax_process_ont_halt();
    return true;
  }
  // Note: If we don't query every time, using the array should be faster; it
  //       means the ajax_ont_init must be called after all the elements
  //       are created because they will not be detected in a dynamic iteration.
  //var linkA = jQuery("a.ont4ajax").first();
  var linkA = ajax_ont_array.shift();
  if(linkA === undefined){
    return true;
  }
  linkA = jQuery(linkA);
  if(linkA.hasClass('ajax-modified-ont') ){
    // How did we get here? It should not have the ont4ajax class!
    linkA.removeClass('ont4ajax');
    return true; // processed this one already.
  }
  linkA.removeClass('ont4ajax'); // processing this one.
  var ont_acronym = linkA.attr('data-ont');
  var ajax_uri = "/ajax/json_ontology/?ontology=" + encodeURIComponent(ont_acronym);
  jQuery.ajax({
    url: ajax_uri,
    timeout: ajax_process_timeout * 1000,
    success: function(data){
      if(typeof data !== "undefined" && data.hasOwnProperty('name')){
        var ont_name = data.name;
        linkA.text(ont_name);
        linkA.addClass('ajax-modified-ont'); // processed this one.
        // find and process any identical ontologies
        jQuery('a[href="/ontologies/' + data.acronym + '"]').each(function(i,e){
          var link = jQuery(this);
          if(! link.hasClass('ajax-modified-ont') ){
            link.removeClass('ont4ajax');   // processing this one.
            link.text(ont_name);
            link.addClass('ajax-modified-ont'); // processed this one.
          }
        });
      }
    },
    error: function(data){
      linkA.addClass('ajax-error'); // processed this one.
    }
  });
};


// **************************************************************************************
// CLASS LABELS

// Note: If we don't query every time, using the array should be faster; it
//       means the ajax_process_init must be called after all the elements
//       are created because they will not be detected in a dynamic iteration.
var ajax_cls_array = [];

var ajax_process_cls_init = function() {
  ajax_cls_array = jQuery("a.cls4ajax").toArray();
  ajax_process_cls_interval = window.setInterval(ajax_process_cls, ajax_process_timing);
};

var ajax_process_cls_halt = function () {
  ajax_cls_array = [];
  window.clearInterval(ajax_process_cls_interval); // stop the ajax process
  // Note: might leave faulty href links, but it usually means moving on to entirely different content
  //       so it's not likely those links will be available for interaction.
  // clear all the classes and ontologies to be resolved by ajax
  //jQuery("a.cls4ajax").removeClass('cls4ajax');
  //jQuery("a.ajax-modified-cls").removeClass('ajax-modified-cls');
};

var ajax_process_cls = function() {
  // Check on whether to stop the ajax process
  if( ajax_cls_array.length === 0 ){
    ajax_process_cls_halt();
    return true;
  }
  // Note: If we don't query every time, using the array should be faster; it
  //       means the ajax_process_init must be called after all the elements
  //       are created because they will not be detected in a dynamic iteration.
  //var linkA = jQuery("a.cls4ajax").first();
  var linkA = ajax_cls_array.shift();
  if(linkA === undefined){
    return true;
  }
  linkA = jQuery(linkA);
  if(linkA.hasClass('ajax-modified-cls') ){
    // How did we get here? It should not have the cls4ajax class!
    linkA.removeClass('cls4ajax');
    return true; // processing or processed this one already.
  }
  linkA.removeClass('cls4ajax'); // processing this one.
  var unique_id = linkA.attr('href');


  // TODO: retrieve 'data-cls' and 'data-ont' attributes.

  var cls_id = linkA.attr('data-cls');
  var ont_acronym = linkA.attr('data-ont');
  var ont_uri = "/ontologies/" + ont_acronym;
  var cls_uri = ont_uri + "?p=classes&conceptid=" + encodeURIComponent(cls_id);
  var ajax_uri = "/ajax/classes/label?ontology=" + ont_acronym + "&concept=" + encodeURIComponent(cls_id);
  jQuery.ajax({
    url: ajax_uri,
    timeout: ajax_process_timeout * 1000,
    success: function(data){
      data = data.trim();
      if (typeof data !== "undefined" && data.length > 0 && data.indexOf("http") !== 0) {
        var cls_name = data;
        linkA.html(cls_name);
        linkA.attr('href', cls_uri);
        linkA.addClass('ajax-modified-cls');
        // find and process any identical classes (low probability)
        jQuery( 'a[href="' + unique_id + '"]').each(function(i,e){
          var link = jQuery(this);
          if(! link.hasClass('ajax-modified-cls') ){
            link.removeClass('cls4ajax');   // processing this one.
            link.html(cls_name);
            link.attr('href', cls_uri);
            link.addClass('ajax-modified-cls'); // processed this one.
          }
        });
      } else {
        // remove the unique_id separator and the ontology acronym from the href
        linkA.attr('href', cls_id);  // it may not be an ontology class, don't use the cls_uri
        linkA.addClass('ajax-modified-cls');
      }
    },
    error: function(data){
      linkA.addClass('ajax-error'); // processed this one.
    }
  });
};

