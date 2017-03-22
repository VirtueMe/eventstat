"use strict";
/* global $ */

$(function() {
  const activateFilter = function() {
    //const sort_by = 'sort_by=' + $('input[name=sort_by]:checked').val()
    //const sort_order = 'sort_order=' + $('input[name=sort_order]:checked').val()
    const from_date = 'from_date=' +$("#daterange_from").val()
    const to_date = 'to_date=' +$("#daterange_to").val()
    const branch = 'branch=' +$("#branch_selector").val()
    // const show_marked = 'show_marked=' + $('input[name=show_marked]:checked').val()

    const link = '/manage_locks?' + branch + '&' +from_date + '&' + to_date;

    window.location.href = link;
  }

})