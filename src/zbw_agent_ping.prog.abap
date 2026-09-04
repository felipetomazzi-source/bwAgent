*&---------------------------------------------------------------------*
*& Report ZBW_AGENT_PING
*&---------------------------------------------------------------------*
*& Phase 1 connectivity test for the read-only BW Agent.
*&
*& Proves the outbound round-trip between BW and the external app:
*&   1. GET  {base}{poll path}      -> fetch pending work (or empty)
*&   2. POST {base}{result path}    -> send a result / heartbeat back
*&
*& It performs no BW metadata reads and changes nothing in BW. It only
*& exercises the HTTP pipe so you can confirm connectivity, TLS trust
*& (STRUST) and auth before wiring in real command handling.
*&---------------------------------------------------------------------*
REPORT zbw_agent_ping.

PARAMETERS:
  p_base   TYPE string LOWER CASE OBLIGATORY,
  p_poll   TYPE string LOWER CASE DEFAULT '/agent/poll',
  p_resp   TYPE string LOWER CASE DEFAULT '/agent/result',
  p_key    TYPE string LOWER CASE,
  p_keyhdr TYPE string LOWER CASE DEFAULT 'X-API-Key',
  p_tout   TYPE i DEFAULT 30.

*&---------------------------------------------------------------------*
CLASS lcl_app DEFINITION CREATE PRIVATE.

  PUBLIC SECTION.
    CLASS-METHODS run.

  PRIVATE SECTION.
    CLASS-METHODS write_response
      IMPORTING
        iv_title    TYPE string
        is_response TYPE zcl_bw_agent_http_client=>ty_response.

    CLASS-METHODS build_result_body
      IMPORTING
        iv_poll_ok    TYPE abap_bool
        iv_poll_code  TYPE i
      RETURNING
        VALUE(rv_body) TYPE string.
ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    DATA(lo_client) = NEW zcl_bw_agent_http_client(
      iv_base_url       = p_base
      iv_api_key        = p_key
      iv_api_key_header = p_keyhdr
      iv_timeout        = p_tout ).

    WRITE: / 'BW Agent connectivity test'.
    WRITE: / 'Base URL :', p_base.
    ULINE.

    " Step 1: poll the external app for pending work.
    DATA(ls_poll) = lo_client->get( p_poll ).
    write_response(
      iv_title    = |STEP 1 - GET { p_poll }|
      is_response = ls_poll ).

    " Step 2: post a result / heartbeat back to the external app.
    DATA(lv_body) = build_result_body(
      iv_poll_ok   = ls_poll-ok
      iv_poll_code = ls_poll-http_code ).

    DATA(ls_resp) = lo_client->post(
      iv_path = p_resp
      iv_body = lv_body ).
    write_response(
      iv_title    = |STEP 2 - POST { p_resp }|
      is_response = ls_resp ).

    ULINE.
    IF ls_poll-ok = abap_true AND ls_resp-ok = abap_true.
      WRITE: / 'RESULT: round-trip OK - the BW -> external app pipe works.'.
    ELSE.
      WRITE: / 'RESULT: round-trip FAILED - see step details above.'.
      WRITE: / 'Common causes: TLS cert not trusted (STRUST / SSL client PSE),'.
      WRITE: / 'wrong base URL, proxy required, or auth rejected.'.
    ENDIF.
  ENDMETHOD.


  METHOD build_result_body.
    " Minimal heartbeat payload. The external app can ignore fields it
    " does not need; this only proves BW can POST a JSON body.
    DATA(lv_ts) = |{ sy-datum }T{ sy-uzeit }|.
    rv_body =
      |\{|                                                        &&
      |"agent":"ZBW_AGENT_PING",|                                 &&
      |"host":"{ sy-host }",|                                     &&
      |"sysid":"{ sy-sysid }",|                                   &&
      |"client":"{ sy-mandt }",|                                  &&
      |"user":"{ sy-uname }",|                                    &&
      |"timestamp":"{ lv_ts }",|                                  &&
      |"poll_ok":{ COND string( WHEN iv_poll_ok = abap_true
                                THEN 'true' ELSE 'false' ) },|    &&
      |"poll_http_code":{ iv_poll_code }|                         &&
      |\}|.
  ENDMETHOD.


  METHOD write_response.
    WRITE: / iv_title.
    IF is_response-error_text IS NOT INITIAL.
      WRITE: /  '  transport error:', is_response-error_text.
      RETURN.
    ENDIF.

    WRITE: /  '  http code :', is_response-http_code.
    WRITE: /  '  reason    :', is_response-reason.
    WRITE: /  '  ok        :', COND string(
                                 WHEN is_response-ok = abap_true
                                 THEN 'yes' ELSE 'no' ).
    WRITE: /  '  body      :'.
    " Body can be long; let it wrap on the list.
    WRITE: /  is_response-body.
    SKIP.
  ENDMETHOD.

ENDCLASS.


START-OF-SELECTION.
  lcl_app=>run( ).
