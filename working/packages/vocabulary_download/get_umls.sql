CREATE OR REPLACE FUNCTION vocabulary_download.get_umls (
iOperation text default null,
out session_id int4,
out last_status INT,
out result_output text
)
AS
$BODY$
DECLARE
pVocabularyID constant text:='UMLS';
pVocabulary_auth vocabulary_access.vocabulary_auth%type;
pVocabulary_url vocabulary_access.vocabulary_url%type;
pVocabulary_login vocabulary_access.vocabulary_login%type;
pVocabulary_pass vocabulary_access.vocabulary_pass%type;
pVocabularySrcDate date;
pVocabularySrcVersion text;
pVocabularyNewDate date;
pVocabularyNewVersion text;
pCookie text;
pContent text;
pDownloadURL text;
auth_hidden_param varchar(10000);
pErrorDetails text;
pVocabularyOperation text;
pJumpToOperation text; --ALL (default), JUMP_TO_UMLS_PREPARE, JUMP_TO_UMLS_IMPORT
z int;
cRet text;
CRLF constant text:=E'\r\n';
pSession int4;
pVocabulary_load_path text;
BEGIN
  pVocabularyOperation:='GET_UMLS';
  select nextval('vocabulary_download.log_seq') into pSession;
  
  select new_date, new_version, src_date, src_version 
  	into pVocabularyNewDate, pVocabularyNewVersion, pVocabularySrcDate, pVocabularySrcVersion 
  from vocabulary_pack.CheckVocabularyUpdate(pVocabularyID);

  set local search_path to vocabulary_download;
  
  perform write_log (
    iVocabularyID=>pVocabularyID,
    iSessionID=>pSession,
    iVocabulary_operation=>pVocabularyOperation||' started',
    iVocabulary_status=>0
  );
  
  if pVocabularyNewDate is null then raise exception '% already updated',pVocabularyID; end if;
  
  if iOperation is null then pJumpToOperation:='ALL'; else pJumpToOperation:=iOperation; end if;
  if iOperation not in ('ALL', 'JUMP_TO_UMLS_PREPARE', 'JUMP_TO_UMLS_IMPORT') then raise exception 'Wrong iOperation %',iOperation; end if;
  
  if not pg_try_advisory_xact_lock(hashtext(pVocabularyID)) then raise exception 'Processing of % already started',pVocabularyID; end if;
  
  select var_value||pVocabularyID into pVocabulary_load_path from devv5.config$ where var_name='vocabulary_load_path';
    
  if pJumpToOperation='ALL' then
    --get credentials
    select vocabulary_auth, vocabulary_url, vocabulary_login, vocabulary_pass, max(vocabulary_order) over()
    into pVocabulary_auth, pVocabulary_url, pVocabulary_login, pVocabulary_pass, z from devv5.vocabulary_access where vocabulary_id=pVocabularyID and vocabulary_order=1;

    --first part, getting raw download link from page
    select substring(http_content,'Full UMLS Release Files.+?<a href="(.+?)">') into pDownloadURL from py_http_get(url=>pVocabulary_url);
    pDownloadURL:=regexp_replace(pDownloadURL, '[[:cntrl:]]+', '','g');
    if not coalesce(pDownloadURL,'-') ~* '^(https://download.nlm.nih.gov/)(.+)\.zip$' then pErrorDetails:=coalesce(pDownloadURL,'-'); raise exception 'pDownloadURL (raw) is not valid'; end if;
    
    --get full working link with proper cookie
    select (select value from json_each_text(http_headers) where lower(key)='set-cookie'),
    (select value from json_each_text(http_headers) where lower(key)='location'),http_content
    into pCookie, pDownloadURL, pContent from py_http_umls (pVocabulary_auth,pDownloadURL,devv5.urlencode(pVocabulary_login),devv5.urlencode(pVocabulary_pass));
    if pCookie not like '%MOD_AUTH_CAS=%' then pErrorDetails:=pCookie||CRLF||CRLF||pContent; raise exception 'cookie %%MOD_AUTH_CAS=%% not found'; end if;
    
    pCookie=substring(pCookie,'MOD_AUTH_CAS=(.*?);');
    
    perform write_log (
      iVocabularyID=>pVocabularyID,
      iSessionID=>pSession,
      iVocabulary_operation=>pVocabularyOperation||' authorization successful',
      iVocabulary_status=>1
    );

    --start downloading
    pVocabularyOperation:='GET_UMLS downloading';
    perform run_wget (
      iPath=>pVocabulary_load_path,
      iFilename=>lower(pVocabularyID)||'.zip',
      iDownloadLink=>pDownloadURL,
      iParams=>'--no-cookies --header "Cookie: MOD_AUTH_CAS='||pCookie||'"'
    );
    perform write_log (
      iVocabularyID=>pVocabularyID,
      iSessionID=>pSession,
      iVocabulary_operation=>'GET_UMLS downloading complete',
      iVocabulary_status=>1
    );
  end if;
  
  if pJumpToOperation in ('ALL','JUMP_TO_UMLS_PREPARE') then
  	pJumpToOperation:='ALL';
    --UMLS needs some preparation (MetaMorphoSys)
    pVocabularyOperation:='GET_UMLS prepare';
    perform get_umls_prepare (
      iPath=>pVocabulary_load_path,
      iFilename=>lower(pVocabularyID)||'.zip'
    );
    perform write_log (
      iVocabularyID=>pVocabularyID,
      iSessionID=>pSession,
      iVocabulary_operation=>'GET_UMLS prepare complete',
      iVocabulary_status=>1
    );
  end if;
  
  if pJumpToOperation in ('ALL','JUMP_TO_UMLS_IMPORT') then
  	pJumpToOperation:='ALL';
    --finally we have all input tables, we can start importing
    pVocabularyOperation:='GET_UMLS load_input_tables';
    perform sources.load_input_tables(pVocabularyID,pVocabularyNewDate,pVocabularyNewVersion);
    perform write_log (
      iVocabularyID=>pVocabularyID,
      iSessionID=>pSession,
      iVocabulary_operation=>'GET_UMLS load_input_tables complete',
      iVocabulary_status=>1
    );
  end if;
    
  perform write_log (
    iVocabularyID=>pVocabularyID,
    iSessionID=>pSession,
    iVocabulary_operation=>'GET_UMLS all tasks done',
    iVocabulary_status=>3
  );
  
  session_id:=pSession;
  last_status:=3;
  result_output:=to_char(pVocabularySrcDate,'YYYYMMDD')||' -> '||to_char(pVocabularyNewDate,'YYYYMMDD')||', '||pVocabularySrcVersion||' -> '||pVocabularyNewVersion;
  return;
  
  EXCEPTION WHEN OTHERS THEN
    get stacked diagnostics cRet = pg_exception_context;
    cRet:='ERROR: '||SQLERRM||CRLF||'CONTEXT: '||cRet;
    set local search_path to vocabulary_download;
    perform write_log (
      iVocabularyID=>pVocabularyID,
      iSessionID=>pSession,
      iVocabulary_operation=>pVocabularyOperation,
      iVocabulary_error=>cRet,
      iError_details=>pErrorDetails,
      iVocabulary_status=>2
    );
    
    session_id:=pSession;
    last_status:=2;
    result_output:=cRet;
    return;
END;
$BODY$
LANGUAGE 'plpgsql'
SECURITY DEFINER;