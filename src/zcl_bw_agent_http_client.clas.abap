CLASS zcl_bw_agent_http_client DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    "! Result of a single HTTP call
    TYPES: BEGIN OF ty_response,
             ok           TYPE abap_bool,   "! abap_true when transport succeeded and status is 2xx
             http_code    TYPE i,           "! HTTP status code (e.g. 200)
             reason       TYPE string,      "! HTTP reason phrase
             body         TYPE string,      "! Response body (character data)
             error_text   TYPE string,      "! Filled when transport-level error occurred
           END OF ty_response.

    "! HTTP header field
    TYPES: BEGIN OF ty_header,
             name  TYPE string,
             value TYPE string,
           END OF ty_header.
    TYPES ty_headers TYPE STANDARD TABLE OF ty_header WITH EMPTY KEY.

    "! @parameter iv_base_url    | Base URL of the external application, e.g. https://ext.example.com/api
    "! @parameter iv_api_key     | Optional API key sent in the configured header (see iv_api_key_header)
    "! @parameter iv_api_key_header | Header name for the API key (default 'X-API-Key')
    "! @parameter iv_timeout     | Receive timeout in seconds (default 30)
    METHODS constructor
      IMPORTING
        iv_base_url        TYPE string
        iv_api_key         TYPE string OPTIONAL
        iv_api_key_header  TYPE string DEFAULT 'X-API-Key'
        iv_timeout         TYPE i DEFAULT 30.

    "! Perform an HTTP GET against base_url + iv_path
    METHODS get
      IMPORTING
        iv_path          TYPE string
        it_headers       TYPE ty_headers OPTIONAL
      RETURNING
        VALUE(rs_response) TYPE ty_response.

    "! Perform an HTTP POST with a (JSON) body against base_url + iv_path
    METHODS post
      IMPORTING
        iv_path            TYPE string
        iv_body            TYPE string
        iv_content_type    TYPE string DEFAULT 'application/json'
        it_headers         TYPE ty_headers OPTIONAL
      RETURNING
        VALUE(rs_response) TYPE ty_response.

  PROTECTED SECTION.

  PRIVATE SECTION.

    DATA mv_base_url       TYPE string.
    DATA mv_api_key        TYPE string.
    DATA mv_api_key_header TYPE string.
    DATA mv_timeout        TYPE i.

    "! Build a client for the full URL, apply common headers, timeout and auth.
    METHODS create_client
      IMPORTING
        iv_path          TYPE string
      EXPORTING
        eo_client        TYPE REF TO if_http_client
        ev_error_text    TYPE string.

    "! Send + receive, translate SAP exceptions into a filled ty_response.
    METHODS send_receive
      IMPORTING
        io_client          TYPE REF TO if_http_client
      RETURNING
        VALUE(rs_response) TYPE ty_response.

    METHODS build_url
      IMPORTING
        iv_path       TYPE string
      RETURNING
        VALUE(rv_url) TYPE string.

ENDCLASS.



CLASS zcl_bw_agent_http_client IMPLEMENTATION.


  METHOD constructor.
    mv_base_url       = iv_base_url.
    mv_api_key        = iv_api_key.
    mv_api_key_header = iv_api_key_header.
    mv_timeout        = iv_timeout.
  ENDMETHOD.


  METHOD build_url.
    " Join base and path avoiding a duplicated '/'
    DATA(lv_base) = mv_base_url.
    DATA(lv_path) = iv_path.

    IF lv_base CP '*/' AND lv_path CP '/*'.
      " base ends with '/' and path starts with '/': drop one
      rv_url = lv_base && lv_path+1.
    ELSEIF ( NOT lv_base CP '*/' ) AND ( NOT lv_path CP '/*' ) AND lv_path IS NOT INITIAL.
      rv_url = lv_base && '/' && lv_path.
    ELSE.
      rv_url = lv_base && lv_path.
    ENDIF.
  ENDMETHOD.


  METHOD create_client.
    DATA(lv_url) = build_url( iv_path ).

    cl_http_client=>create_by_url(
      EXPORTING
        url                = lv_url
        ssl_id             = 'ANONYM'
      IMPORTING
        client             = eo_client
      EXCEPTIONS
        argument_not_found = 1
        plugin_not_active  = 2
        internal_error     = 3
        OTHERS             = 4 ).

    IF sy-subrc <> 0.
      ev_error_text = |create_by_url failed for { lv_url } (sy-subrc={ sy-subrc })|.
      CLEAR eo_client.
      RETURN.
    ENDIF.

    " Do not raise on HTTP error status; we inspect the code ourselves.
    eo_client->propertytype_logon_popup = if_http_client=>co_disabled.

    IF mv_timeout > 0.
      eo_client->set_timeout( mv_timeout ).
    ENDIF.

    " Common headers
    eo_client->request->set_header_field(
      name  = 'Accept'
      value = 'application/json' ).

    " API key auth (optional)
    IF mv_api_key IS NOT INITIAL AND mv_api_key_header IS NOT INITIAL.
      eo_client->request->set_header_field(
        name  = mv_api_key_header
        value = mv_api_key ).
    ENDIF.
  ENDMETHOD.


  METHOD send_receive.
    DATA lv_code   TYPE i.
    DATA lv_reason TYPE string.

    io_client->send(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        http_invalid_timeout       = 4
        OTHERS                     = 5 ).

    IF sy-subrc <> 0.
      io_client->get_last_error( IMPORTING message = rs_response-error_text ).
      IF rs_response-error_text IS INITIAL.
        rs_response-error_text = |send failed (sy-subrc={ sy-subrc })|.
      ENDIF.
      io_client->close( EXCEPTIONS OTHERS = 0 ).
      RETURN.
    ENDIF.

    io_client->receive(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        OTHERS                     = 4 ).

    IF sy-subrc <> 0.
      io_client->get_last_error( IMPORTING message = rs_response-error_text ).
      IF rs_response-error_text IS INITIAL.
        rs_response-error_text = |receive failed (sy-subrc={ sy-subrc })|.
      ENDIF.
      io_client->close( EXCEPTIONS OTHERS = 0 ).
      RETURN.
    ENDIF.

    io_client->response->get_status(
      IMPORTING
        code   = lv_code
        reason = lv_reason ).

    rs_response-http_code = lv_code.
    rs_response-reason    = lv_reason.
    rs_response-body      = io_client->response->get_cdata( ).
    rs_response-ok        = boolc( lv_code >= 200 AND lv_code < 300 ).

    io_client->close( EXCEPTIONS OTHERS = 0 ).
  ENDMETHOD.


  METHOD get.
    DATA lo_client TYPE REF TO if_http_client.
    DATA lv_error  TYPE string.

    create_client(
      EXPORTING iv_path       = iv_path
      IMPORTING eo_client     = lo_client
                ev_error_text = lv_error ).

    IF lo_client IS INITIAL.
      rs_response-error_text = lv_error.
      RETURN.
    ENDIF.

    lo_client->request->set_method( if_http_request=>co_request_method_get ).

    LOOP AT it_headers INTO DATA(ls_header).
      lo_client->request->set_header_field(
        name  = ls_header-name
        value = ls_header-value ).
    ENDLOOP.

    rs_response = send_receive( lo_client ).
  ENDMETHOD.


  METHOD post.
    DATA lo_client TYPE REF TO if_http_client.
    DATA lv_error  TYPE string.

    create_client(
      EXPORTING iv_path       = iv_path
      IMPORTING eo_client     = lo_client
                ev_error_text = lv_error ).

    IF lo_client IS INITIAL.
      rs_response-error_text = lv_error.
      RETURN.
    ENDIF.

    lo_client->request->set_method( if_http_request=>co_request_method_post ).
    lo_client->request->set_header_field(
      name  = 'Content-Type'
      value = iv_content_type ).

    LOOP AT it_headers INTO DATA(ls_header).
      lo_client->request->set_header_field(
        name  = ls_header-name
        value = ls_header-value ).
    ENDLOOP.

    lo_client->request->set_cdata( iv_body ).

    rs_response = send_receive( lo_client ).
  ENDMETHOD.


ENDCLASS.
