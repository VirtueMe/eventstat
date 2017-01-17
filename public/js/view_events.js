"use strict";
/* global $ */

$(function() {
  $('#branch_selector').children().first().prop('selected', true);

  $("#branch_selector").click(function() {
    var branchID = $(this).val();

    if (branchID === '0') {
      $("#event_table tr").show();
    } else {
      $("#event_table tr:not(:first)").hide();
      $("#event_table ." + branchID).show();
    }
  });
});
