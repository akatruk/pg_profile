/* ===== Tables stats functions ===== */

CREATE OR REPLACE FUNCTION top_tables(IN snode_id integer, IN start_id integer, IN end_id integer)
RETURNS TABLE(
    node_id integer,
    datid oid,
    relid oid,
    reltoastrelid oid,
    dbname name,
    tablespacename name,
    schemaname name,
    relname name,
    seq_scan bigint,
    seq_tup_read bigint,
    seq_scan_page_cnt bigint,
    idx_scan bigint,
    idx_tup_fetch bigint,
    n_tup_ins bigint,
    n_tup_upd bigint,
    n_tup_del bigint,
    n_tup_hot_upd bigint,
    vacuum_count bigint,
    autovacuum_count bigint,
    analyze_count bigint,
    autoanalyze_count bigint,
    growth bigint,
    toastseq_scan bigint,
    toastseq_tup_read bigint,
    toastseq_scan_page_cnt bigint,
    toastidx_scan bigint,
    toastidx_tup_fetch bigint,
    toastn_tup_ins bigint,
    toastn_tup_upd bigint,
    toastn_tup_del bigint,
    toastn_tup_hot_upd bigint,
    toastvacuum_count bigint,
    toastautovacuum_count bigint,
    toastanalyze_count bigint,
    toastautoanalyze_count bigint,
    toastgrowth bigint
) SET search_path=@extschema@,public AS $$
    SELECT
        st.node_id,
        st.datid,
        st.relid,
        st.reltoastrelid,
        snap_db.datname AS dbname,
        tl.tablespacename,
        st.schemaname,
        st.relname,
        sum(st.seq_scan)::bigint AS seq_scan,
        sum(st.seq_tup_read)::bigint AS seq_tup_read,
        sum(st.seq_scan * st.relsize / prm.setting::double precision)::bigint seq_scan_page_cnt,
        sum(st.idx_scan)::bigint AS idx_scan,
        sum(st.idx_tup_fetch)::bigint AS idx_tup_fetch,
        sum(st.n_tup_ins)::bigint AS n_tup_ins,
        sum(st.n_tup_upd)::bigint AS n_tup_upd,
        sum(st.n_tup_del)::bigint AS n_tup_del,
        sum(st.n_tup_hot_upd)::bigint AS n_tup_hot_upd,
        sum(st.vacuum_count)::bigint AS vacuum_count,
        sum(st.autovacuum_count)::bigint AS autovacuum_count,
        sum(st.analyze_count)::bigint AS analyze_count,
        sum(st.autoanalyze_count)::bigint AS autoanalyze_count,
        sum(st.relsize_diff)::bigint AS growth,
        sum(stt.seq_scan)::bigint AS toastseq_scan,
        sum(stt.seq_tup_read)::bigint AS toastseq_tup_read,
        sum(stt.seq_scan * stt.relsize / prm.setting::double precision)::bigint toastseq_scan_page_cnt,
        sum(stt.idx_scan)::bigint AS toastidx_scan,
        sum(stt.idx_tup_fetch)::bigint AS toastidx_tup_fetch,
        sum(stt.n_tup_ins)::bigint AS toastn_tup_ins,
        sum(stt.n_tup_upd)::bigint AS toastn_tup_upd,
        sum(stt.n_tup_del)::bigint AS toastn_tup_del,
        sum(stt.n_tup_hot_upd)::bigint AS toastn_tup_hot_upd,
        sum(stt.vacuum_count)::bigint AS toastvacuum_count,
        sum(stt.autovacuum_count)::bigint AS toastautovacuum_count,
        sum(stt.analyze_count)::bigint AS toastanalyze_count,
        sum(stt.autoanalyze_count)::bigint AS tosatautoanalyze_count,
        sum(stt.relsize_diff)::bigint AS toastgrowth
    FROM v_snap_stat_tables st
        -- Database name
        JOIN snap_stat_database snap_db
          USING (node_id, snap_id, datid)
        JOIN tablespaces_list tl USING (node_id, tablespaceid)
        -- block size (for seq_scan page count estimate)
        JOIN v_snap_settings prm ON (st.node_id = prm.node_id AND st.snap_id = prm.snap_id AND prm.name = 'block_size')
        /* Start snapshot existance condition
        Start snapshot stats does not account in report, but we must be sure
        that start snapshot exists, as it is reference point of next snapshot
        */
        JOIN snapshots snap_s ON (st.node_id = snap_s.node_id AND snap_s.snap_id = start_id)
        /* End snapshot existance condition
        Make sure that end snapshot exists, so we really account full interval
        */
        JOIN snapshots snap_e ON (st.node_id = snap_e.node_id AND snap_e.snap_id = end_id)
        LEFT OUTER JOIN v_snap_stat_tables stt -- TOAST stats
        ON (st.node_id=stt.node_id AND st.snap_id=stt.snap_id AND st.datid=stt.datid AND st.reltoastrelid=stt.relid)
    WHERE st.node_id = snode_id AND st.relkind IN ('r','m') AND snap_db.datname NOT LIKE 'template_'
      AND st.snap_id BETWEEN snap_s.snap_id + 1 AND snap_e.snap_id
    GROUP BY st.node_id,st.datid,st.relid,st.reltoastrelid,snap_db.datname,tl.tablespacename,st.schemaname,st.relname
    --HAVING min(snap_db.stats_reset) = max(snap_db.stats_reset)
$$ LANGUAGE sql;

/* ===== Objects report functions ===== */
CREATE OR REPLACE FUNCTION top_scan_tables_htbl(IN jreportset jsonb, IN snode_id integer, IN start_id integer, IN end_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT
        dbname,
        tablespacename,
        schemaname,
        relname,
        reltoastrelid,
        seq_scan,
        seq_scan_page_cnt,
        idx_scan,
        idx_tup_fetch,
        n_tup_ins,
        n_tup_upd,
        n_tup_del,
        n_tup_hot_upd,
        toastseq_scan,
        toastseq_scan_page_cnt,
        toastidx_scan,
        toastidx_tup_fetch,
        toastn_tup_ins,
        toastn_tup_upd,
        toastn_tup_del,
        toastn_tup_hot_upd
    FROM top_tables(snode_id, start_id, end_id)
    WHERE seq_scan > 0
    ORDER BY seq_scan_page_cnt+COALESCE(toastseq_scan_page_cnt,0) DESC
    LIMIT topn;

    r_result RECORD;
BEGIN
    --- Populate templates
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table><tr><th>DB</th><th>Tablespace</th><th>Schema</th><th>Table</th><th>SeqScan</th><th>SeqPages</th><th>IxScan</th><th>IxFet</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th></tr>{rows}</table>',
      'rel_tpl','<tr {reltr}><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>',
      'rel_wtoast_tpl','<tr {reltr}><td  {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr {toasttr}><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr><tr style="visibility:collapse"></tr>');

    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);


    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        IF r_result.reltoastrelid IS NULL THEN
          report := report||format(
              jtab_tpl #>> ARRAY['rel_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.seq_scan,
              r_result.seq_scan_page_cnt,
              r_result.idx_scan,
              r_result.idx_tup_fetch,
              r_result.n_tup_ins,
              r_result.n_tup_upd,
              r_result.n_tup_del,
              r_result.n_tup_hot_upd
          );
        ELSE
          report := report||format(
              jtab_tpl #>> ARRAY['rel_wtoast_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.seq_scan,
              r_result.seq_scan_page_cnt,
              r_result.idx_scan,
              r_result.idx_tup_fetch,
              r_result.n_tup_ins,
              r_result.n_tup_upd,
              r_result.n_tup_del,
              r_result.n_tup_hot_upd,
              r_result.relname||'(TOAST)',
              r_result.toastseq_scan,
              r_result.toastseq_scan_page_cnt,
              r_result.toastidx_scan,
              r_result.toastidx_tup_fetch,
              r_result.toastn_tup_ins,
              r_result.toastn_tup_upd,
              r_result.toastn_tup_del,
              r_result.toastn_tup_hot_upd
          );
        END IF;
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_scan_tables_diff_htbl(IN jreportset jsonb, IN snode_id integer, IN start1_id integer, IN end1_id integer,
IN start2_id integer, IN end2_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT * FROM (SELECT
        COALESCE(tbl1.dbname,tbl2.dbname) AS dbname,
        COALESCE(tbl1.tablespacename,tbl2.tablespacename) AS tablespacename,
        COALESCE(tbl1.schemaname,tbl2.schemaname) AS schemaname,
        COALESCE(tbl1.relname,tbl2.relname) AS relname,
        tbl1.seq_scan AS seq_scan1,
        tbl1.seq_scan_page_cnt AS seq_scan_page_cnt1,
        tbl1.idx_scan AS idx_scan1,
        tbl1.idx_tup_fetch AS idx_tup_fetch1,
        tbl1.toastseq_scan AS toastseq_scan1,
        tbl1.toastseq_scan_page_cnt AS toastseq_scan_page_cnt1,
        tbl1.toastidx_scan AS toastidx_scan1,
        tbl1.toastidx_tup_fetch AS toastidx_tup_fetch1,
        tbl2.seq_scan AS seq_scan2,
        tbl2.seq_scan_page_cnt AS seq_scan_page_cnt2,
        tbl2.idx_scan AS idx_scan2,
        tbl2.idx_tup_fetch AS idx_tup_fetch2,
        tbl2.toastseq_scan AS toastseq_scan2,
        tbl2.toastseq_scan_page_cnt AS toastseq_scan_page_cnt2,
        tbl2.toastidx_scan AS toastidx_scan2,
        tbl2.toastidx_tup_fetch AS toastidx_tup_fetch2,
        row_number() over (ORDER BY tbl1.seq_scan_page_cnt + tbl1.toastseq_scan_page_cnt DESC NULLS LAST) AS rn_seqpg1,
        row_number() over (ORDER BY tbl2.seq_scan_page_cnt + tbl2.toastseq_scan_page_cnt DESC NULLS LAST) AS rn_seqpg2
    FROM top_tables(snode_id, start1_id, end1_id) tbl1
        FULL OUTER JOIN top_tables(snode_id, start2_id, end2_id) tbl2 USING (node_id, datid, relid)
    WHERE COALESCE(tbl1.seq_scan,tbl1.toastseq_scan,tbl2.seq_scan,tbl2.toastseq_scan) > 0
    ORDER BY COALESCE(tbl1.seq_scan_page_cnt,0) +
      COALESCE(tbl1.toastseq_scan_page_cnt,0) +
      COALESCE(tbl2.seq_scan_page_cnt,0) +
      COALESCE(tbl2.toastseq_scan_page_cnt,0)
    DESC) t1
    WHERE rn_seqpg1 <= topn OR rn_seqpg2 <= topn;

    r_result RECORD;
BEGIN
    -- Tables stats template
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table {difftbl}><tr><th rowspan="2">DB</th><th rowspan="2">Tablespace</th><th rowspan="2">Schema</th><th rowspan="2">Table</th><th rowspan="2">I</th><th colspan="4">Table</th><th colspan="4">TOAST</th></tr>'||
      '<tr><th>SeqScan</th><th>SeqPages</th><th>IxScan</th><th>IxFet</th><th>SeqScan</th><th>SeqPages</th><th>IxScan</th><th>IxFet</th></tr>{rows}</table>',
      'row_tpl','<tr {interval1}><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {label} {title1}>1</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
          '<td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
        '</tr><tr {interval2}><td {label} {title2}>2</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr style="visibility:collapse"></tr>');
    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);
    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        report := report||format(
            jtab_tpl #>> ARRAY['row_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.seq_scan1,
            r_result.seq_scan_page_cnt1,
            r_result.idx_scan1,
            r_result.idx_tup_fetch1,
            r_result.toastseq_scan1,
            r_result.toastseq_scan_page_cnt1,
            r_result.toastidx_scan1,
            r_result.toastidx_tup_fetch1,
            r_result.seq_scan2,
            r_result.seq_scan_page_cnt2,
            r_result.idx_scan2,
            r_result.idx_tup_fetch2,
            r_result.toastseq_scan2,
            r_result.toastseq_scan_page_cnt2,
            r_result.toastidx_scan2,
            r_result.toastidx_tup_fetch2
        );
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_dml_tables_htbl(IN jreportset jsonb, IN snode_id integer, IN start_id integer, IN end_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT
        dbname,
        tablespacename,
        schemaname,
        relname,
        reltoastrelid,
        seq_scan,
        seq_tup_read,
        idx_scan,
        idx_tup_fetch,
        n_tup_ins,
        n_tup_upd,
        n_tup_del,
        n_tup_hot_upd,
        toastseq_scan,
        toastseq_tup_read,
        toastidx_scan,
        toastidx_tup_fetch,
        toastn_tup_ins,
        toastn_tup_upd,
        toastn_tup_del,
        toastn_tup_hot_upd
    FROM top_tables(snode_id, start_id, end_id)
    WHERE n_tup_ins+n_tup_upd+n_tup_del+
      COALESCE(toastn_tup_ins+toastn_tup_upd+toastn_tup_del,0)> 0
    ORDER BY n_tup_ins+n_tup_upd+n_tup_del+
      COALESCE(toastn_tup_ins+toastn_tup_upd+toastn_tup_del,0) DESC
    LIMIT topn;

    r_result RECORD;
BEGIN

    -- Populate templates
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table><tr><th>DB</th><th>Tablespace</th><th>Schema</th><th>Table</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th><th>SeqScan</th><th>SeqFet</th><th>IxScan</th><th>IxFet</th></tr>{rows}</table>',
      'rel_tpl','<tr {reltr}><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>',
      'rel_wtoast_tpl','<tr {reltr}><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr {toasttr}><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr><tr style="visibility:collapse"></tr>');

    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);

    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        IF r_result.reltoastrelid IS NULL THEN
          report := report||format(
              jtab_tpl #>> ARRAY['rel_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.n_tup_ins,
              r_result.n_tup_upd,
              r_result.n_tup_del,
              r_result.n_tup_hot_upd,
              r_result.seq_scan,
              r_result.seq_tup_read,
              r_result.idx_scan,
              r_result.idx_tup_fetch
          );
        ELSE
          report := report||format(
              jtab_tpl #>> ARRAY['rel_wtoast_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.n_tup_ins,
              r_result.n_tup_upd,
              r_result.n_tup_del,
              r_result.n_tup_hot_upd,
              r_result.seq_scan,
              r_result.seq_tup_read,
              r_result.idx_scan,
              r_result.idx_tup_fetch,
              r_result.relname||'(TOAST)',
              r_result.toastn_tup_ins,
              r_result.toastn_tup_upd,
              r_result.toastn_tup_del,
              r_result.toastn_tup_hot_upd,
              r_result.toastseq_scan,
              r_result.toastseq_tup_read,
              r_result.toastidx_scan,
              r_result.toastidx_tup_fetch
          );
        END IF;
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_dml_tables_diff_htbl(IN jreportset jsonb, IN snode_id integer, IN start1_id integer, IN end1_id integer,
IN start2_id integer, IN end2_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT * FROM (SELECT
        COALESCE(tbl1.dbname,tbl2.dbname) AS dbname,
        COALESCE(tbl1.tablespacename,tbl2.tablespacename) AS tablespacename,
        COALESCE(tbl1.schemaname,tbl2.schemaname) AS schemaname,
        COALESCE(tbl1.relname,tbl2.relname) AS relname,
        tbl1.n_tup_ins AS n_tup_ins1,
        tbl1.n_tup_upd AS n_tup_upd1,
        tbl1.n_tup_del AS n_tup_del1,
        tbl1.n_tup_hot_upd AS n_tup_hot_upd1,
        tbl1.toastn_tup_ins AS toastn_tup_ins1,
        tbl1.toastn_tup_upd AS toastn_tup_upd1,
        tbl1.toastn_tup_del AS toastn_tup_del1,
        tbl1.toastn_tup_hot_upd AS toastn_tup_hot_upd1,
        tbl2.n_tup_ins AS n_tup_ins2,
        tbl2.n_tup_upd AS n_tup_upd2,
        tbl2.n_tup_del AS n_tup_del2,
        tbl2.n_tup_hot_upd AS n_tup_hot_upd2,
        tbl2.toastn_tup_ins AS toastn_tup_ins2,
        tbl2.toastn_tup_upd AS toastn_tup_upd2,
        tbl2.toastn_tup_del AS toastn_tup_del2,
        tbl2.toastn_tup_hot_upd AS toastn_tup_hot_upd2,
        row_number() OVER (ORDER BY tbl1.n_tup_ins + tbl1.n_tup_upd + tbl1.n_tup_del +
          tbl1.toastn_tup_ins + tbl1.toastn_tup_upd + tbl1.toastn_tup_del DESC NULLS LAST) AS rn_dml1,
        row_number() OVER (ORDER BY tbl2.n_tup_ins + tbl2.n_tup_upd + tbl2.n_tup_del +
          tbl2.toastn_tup_ins + tbl2.toastn_tup_upd + tbl2.toastn_tup_del DESC NULLS LAST) AS rn_dml2
    FROM top_tables(snode_id, start1_id, end1_id) tbl1
        FULL OUTER JOIN top_tables(snode_id, start2_id, end2_id) tbl2 USING (node_id, datid, relid)
    WHERE COALESCE(tbl1.n_tup_ins + tbl1.n_tup_upd + tbl1.n_tup_del,
        tbl1.toastn_tup_ins + tbl1.toastn_tup_upd + tbl1.toastn_tup_del,
        tbl2.n_tup_ins + tbl2.n_tup_upd + tbl2.n_tup_del,
        tbl2.toastn_tup_ins + tbl2.toastn_tup_upd + tbl2.toastn_tup_del, 0) > 0
    ORDER BY COALESCE(tbl1.n_tup_ins + tbl1.n_tup_upd + tbl1.n_tup_del +
          tbl1.toastn_tup_ins + tbl1.toastn_tup_upd + tbl1.toastn_tup_del,0) +
          COALESCE(tbl2.n_tup_ins + tbl2.n_tup_upd + tbl2.n_tup_del +
          tbl2.toastn_tup_ins + tbl2.toastn_tup_upd + tbl2.toastn_tup_del,0) DESC) t1
    WHERE rn_dml1 <= topn OR rn_dml2 <= topn;

    r_result RECORD;
BEGIN
    -- Tables stats template
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table {difftbl}><tr><th rowspan="2">DB</th><th rowspan="2">Tablespace</th><th rowspan="2">Schema</th><th rowspan="2">Table</th><th rowspan="2">I</th><th colspan="4">Table</th><th colspan="4">TOAST</th></tr>'||
      '<tr><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th></tr>{rows}</table>',
      'row_tpl','<tr {interval1}><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {label} {title1}>1</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
          '<td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
        '</tr><tr {interval2}><td {label} {title2}>2</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr style="visibility:collapse"></tr>');
    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);
    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        report := report||format(
            jtab_tpl #>> ARRAY['row_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.n_tup_ins1,
            r_result.n_tup_upd1,
            r_result.n_tup_del1,
            r_result.n_tup_hot_upd1,
            r_result.toastn_tup_ins1,
            r_result.toastn_tup_upd1,
            r_result.toastn_tup_del1,
            r_result.toastn_tup_hot_upd1,
            r_result.n_tup_ins2,
            r_result.n_tup_upd2,
            r_result.n_tup_del2,
            r_result.n_tup_hot_upd2,
            r_result.toastn_tup_ins2,
            r_result.toastn_tup_upd2,
            r_result.toastn_tup_del2,
            r_result.toastn_tup_hot_upd2
        );
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_upd_vac_tables_htbl(IN jreportset jsonb, IN snode_id integer,
IN start_id integer, IN end_id integer, IN topn integer)
RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT
        dbname,
        tablespacename,
        schemaname,
        relname,
        reltoastrelid,
        n_tup_upd,
        n_tup_del,
        n_tup_hot_upd,
        vacuum_count,
        autovacuum_count,
        analyze_count,
        autoanalyze_count,
        toastn_tup_upd,
        toastn_tup_del,
        toastn_tup_hot_upd,
        toastvacuum_count,
        toastautovacuum_count,
        toastanalyze_count,
        toastautoanalyze_count
    FROM top_tables(snode_id, start_id, end_id)
    WHERE n_tup_upd+n_tup_del+
      COALESCE(toastn_tup_upd+toastn_tup_del,0) > 0
    ORDER BY n_tup_upd+n_tup_del+
      COALESCE(toastn_tup_upd+toastn_tup_del,0) DESC
    LIMIT topn;

    r_result RECORD;
BEGIN
    -- Populate templates
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table><tr><th>DB</th><th>Tablespace</th><th>Schema</th><th>Table</th><th>Upd</th><th>Upd(HOT)</th><th>Del</th><th>Vacuum</th><th>AutoVacuum</th><th>Analyze</th><th>AutoAnalyze</th></tr>{rows}</table>',
      'rel_tpl','<tr {reltr}><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>',
      'rel_wtoast_tpl','<tr {reltr}><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr {toasttr}><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr><tr style="visibility:collapse"></tr>');

    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);

    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        IF r_result.reltoastrelid IS NULL THEN
          report := report||format(
              jtab_tpl #>> ARRAY['rel_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.n_tup_upd,
              r_result.n_tup_hot_upd,
              r_result.n_tup_del,
              r_result.vacuum_count,
              r_result.autovacuum_count,
              r_result.analyze_count,
              r_result.autoanalyze_count
          );
        ELSE
          report := report||format(
              jtab_tpl #>> ARRAY['rel_wtoast_tpl'],
              r_result.dbname,
              r_result.tablespacename,
              r_result.schemaname,
              r_result.relname,
              r_result.n_tup_upd,
              r_result.n_tup_hot_upd,
              r_result.n_tup_del,
              r_result.vacuum_count,
              r_result.autovacuum_count,
              r_result.analyze_count,
              r_result.autoanalyze_count,
              r_result.relname||'(TOAST)',
              r_result.toastn_tup_upd,
              r_result.toastn_tup_hot_upd,
              r_result.toastn_tup_del,
              r_result.toastvacuum_count,
              r_result.toastautovacuum_count,
              r_result.toastanalyze_count,
              r_result.toastautoanalyze_count
          );
        END IF;
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_upd_vac_tables_diff_htbl(IN jreportset jsonb, IN snode_id integer, IN start1_id integer, IN end1_id integer,
IN start2_id integer, IN end2_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT * FROM (SELECT
        COALESCE(tbl1.dbname,tbl2.dbname) as dbname,
        COALESCE(tbl1.tablespacename,tbl2.tablespacename) AS tablespacename,
        COALESCE(tbl1.schemaname,tbl2.schemaname) as schemaname,
        COALESCE(tbl1.relname,tbl2.relname) as relname,
        tbl1.n_tup_upd as n_tup_upd1,
        tbl1.n_tup_del as n_tup_del1,
        tbl1.n_tup_hot_upd as n_tup_hot_upd1,
        tbl1.vacuum_count as vacuum_count1,
        tbl1.autovacuum_count as autovacuum_count1,
        tbl1.analyze_count as analyze_count1,
        tbl1.autoanalyze_count as autoanalyze_count1,
        tbl2.n_tup_upd as n_tup_upd2,
        tbl2.n_tup_del as n_tup_del2,
        tbl2.n_tup_hot_upd as n_tup_hot_upd2,
        tbl2.vacuum_count as vacuum_count2,
        tbl2.autovacuum_count as autovacuum_count2,
        tbl2.analyze_count as analyze_count2,
        tbl2.autoanalyze_count as autoanalyze_count2,
        row_number() OVER (ORDER BY tbl1.n_tup_upd + tbl1.n_tup_del DESC NULLS LAST) as rn_vactpl1,
        row_number() OVER (ORDER BY tbl2.n_tup_upd + tbl2.n_tup_del DESC NULLS LAST) as rn_vactpl2
    FROM top_tables(snode_id, start1_id, end1_id) tbl1
        FULL OUTER JOIN top_tables(snode_id, start2_id, end2_id) tbl2 USING (node_id, datid, relid)
    WHERE COALESCE(tbl1.n_tup_upd + tbl1.n_tup_del,
            tbl2.n_tup_upd + tbl2.n_tup_del) > 0
    ORDER BY COALESCE(tbl1.n_tup_upd + tbl1.n_tup_del,0) +
          COALESCE(tbl2.n_tup_upd + tbl2.n_tup_del,0) DESC) t1
    WHERE rn_vactpl1 <= topn OR rn_vactpl2 <= topn;

    r_result RECORD;
BEGIN
    -- Tables stats template
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table {difftbl}><tr><th>DB</th><th>Tablespace</th><th>Schema</th><th>Table</th><th>I</th><th>Upd</th><th>Upd(HOT)</th><th>Del</th><th>Vacuum</th><th>AutoVacuum</th><th>Analyze</th><th>AutoAnalyze</th></tr>{rows}</table>',
      'row_tpl','<tr {interval1}><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {label} {title1}>1</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr {interval2}><td {label} {title2}>2</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr><tr style="visibility:collapse"></tr>');
    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);
    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        report := report||format(
            jtab_tpl #>> ARRAY['row_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.n_tup_upd1,
            r_result.n_tup_hot_upd1,
            r_result.n_tup_del1,
            r_result.vacuum_count1,
            r_result.autovacuum_count1,
            r_result.analyze_count1,
            r_result.autoanalyze_count1,
            r_result.n_tup_upd2,
            r_result.n_tup_hot_upd2,
            r_result.n_tup_del2,
            r_result.vacuum_count2,
            r_result.autovacuum_count2,
            r_result.analyze_count2,
            r_result.autoanalyze_count2
        );
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_growth_tables_htbl(IN jreportset jsonb, IN snode_id integer, IN start_id integer, IN end_id integer, IN topn integer) RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT
        dbname,
        top.tablespacename,
        top.schemaname,
        top.relname,
        top.reltoastrelid,
        top.n_tup_ins,
        top.n_tup_upd,
        top.n_tup_del,
        top.n_tup_hot_upd,
        pg_size_pretty(top.growth) AS growth,
        pg_size_pretty(st_last.relsize) AS relsize,
        top.toastn_tup_ins,
        top.toastn_tup_upd,
        top.toastn_tup_del,
        top.toastn_tup_hot_upd,
        pg_size_pretty(top.toastgrowth) AS toastgrowth,
        pg_size_pretty(stt_last.relsize) AS toastrelsize
    FROM top_tables(snode_id, start_id, end_id) top
        JOIN v_snap_stat_tables st_last
          ON (top.node_id=st_last.node_id AND top.datid=st_last.datid AND top.relid=st_last.relid)
        LEFT OUTER JOIN v_snap_stat_tables stt_last
          ON (top.node_id=stt_last.node_id AND top.datid=stt_last.datid AND top.reltoastrelid=stt_last.relid AND stt_last.snap_id=end_id)
    WHERE st_last.snap_id=end_id AND top.growth + COALESCE (top.toastgrowth,0) > 0
    ORDER BY top.growth + COALESCE (top.toastgrowth,0) DESC
    LIMIT topn;

    r_result RECORD;
BEGIN

    -- Populate templates
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table><tr><th>DB</th><th>Tablespace</th><th>Schema</th><th>Table</th><th>Size</th><th>Growth</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th></tr>{rows}</table>',
      'rel_tpl','<tr {reltr}><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td {reltdhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>',
      'rel_wtoast_tpl','<tr {reltr}><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td {reltdspanhdr}>%s</td><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr {toasttr}><td>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr><tr style="visibility:collapse"></tr>');

    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);

    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
      IF r_result.reltoastrelid IS NULL THEN
        report := report||format(
            jtab_tpl #>> ARRAY['rel_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.relsize,
            r_result.growth,
            r_result.n_tup_ins,
            r_result.n_tup_upd,
            r_result.n_tup_del,
            r_result.n_tup_hot_upd
        );
      ELSE
        report := report||format(
            jtab_tpl #>> ARRAY['rel_wtoast_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.relsize,
            r_result.growth,
            r_result.n_tup_ins,
            r_result.n_tup_upd,
            r_result.n_tup_del,
            r_result.n_tup_hot_upd,
            r_result.relname||'(TOAST)',
            r_result.toastrelsize,
            r_result.toastgrowth,
            r_result.toastn_tup_ins,
            r_result.toastn_tup_upd,
            r_result.toastn_tup_del,
            r_result.toastn_tup_hot_upd
        );
      END IF;
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION top_growth_tables_diff_htbl(IN jreportset jsonb, IN snode_id integer, IN start1_id integer, IN end1_id integer,
    IN start2_id integer, IN end2_id integer, IN topn integer)
RETURNS text SET search_path=@extschema@,public AS $$
DECLARE
    report text := '';

    -- Table elements template collection
    jtab_tpl    jsonb;

    --Cursor for tables stats
    c_tbl_stats CURSOR FOR
    SELECT * FROM (SELECT
        COALESCE(tbl1.dbname,tbl2.dbname) as dbname,
        COALESCE(tbl1.tablespacename,tbl2.tablespacename) AS tablespacename,
        COALESCE(tbl1.schemaname,tbl2.schemaname) as schemaname,
        COALESCE(tbl1.relname,tbl2.relname) as relname,
        tbl1.n_tup_ins as n_tup_ins1,
        tbl1.n_tup_upd as n_tup_upd1,
        tbl1.n_tup_del as n_tup_del1,
        tbl1.n_tup_hot_upd as n_tup_hot_upd1,
        pg_size_pretty(tbl1.growth) AS growth1,
        pg_size_pretty(st_last1.relsize) AS relsize1,
        tbl1.toastn_tup_ins as toastn_tup_ins1,
        tbl1.toastn_tup_upd as toastn_tup_upd1,
        tbl1.toastn_tup_del as toastn_tup_del1,
        tbl1.toastn_tup_hot_upd as toastn_tup_hot_upd1,
        pg_size_pretty(tbl1.toastgrowth) AS toastgrowth1,
        pg_size_pretty(stt_last1.relsize) AS toastrelsize1,
        tbl2.n_tup_ins as n_tup_ins2,
        tbl2.n_tup_upd as n_tup_upd2,
        tbl2.n_tup_del as n_tup_del2,
        tbl2.n_tup_hot_upd as n_tup_hot_upd2,
        pg_size_pretty(tbl2.growth) AS growth2,
        pg_size_pretty(st_last2.relsize) AS relsize2,
        tbl2.toastn_tup_ins as toastn_tup_ins2,
        tbl2.toastn_tup_upd as toastn_tup_upd2,
        tbl2.toastn_tup_del as toastn_tup_del2,
        tbl2.toastn_tup_hot_upd as toastn_tup_hot_upd2,
        pg_size_pretty(tbl2.toastgrowth) AS toastgrowth2,
        pg_size_pretty(stt_last2.relsize) AS toastrelsize2,
        row_number() OVER (ORDER BY tbl1.growth + tbl1.toastgrowth DESC NULLS LAST) as rn_growth1,
        row_number() OVER (ORDER BY tbl2.growth + tbl2.toastgrowth DESC NULLS LAST) as rn_growth2
    FROM top_tables(snode_id, start1_id, end1_id) tbl1
        FULL OUTER JOIN top_tables(snode_id, start2_id, end2_id) tbl2 USING (node_id,datid,relid)
        LEFT OUTER JOIN v_snap_stat_tables st_last1 ON (tbl1.node_id = st_last1.node_id
          AND tbl1.datid = st_last1.datid AND tbl1.relid = st_last1.relid AND st_last1.snap_id=end1_id)
        LEFT OUTER JOIN v_snap_stat_tables st_last2 ON (tbl2.node_id = st_last2.node_id
          AND tbl2.datid = st_last2.datid AND tbl2.relid = st_last2.relid AND st_last2.snap_id=end2_id)
        -- join toast tables last snapshot stats (to get relsize)
        LEFT OUTER JOIN v_snap_stat_tables stt_last1 ON (st_last1.node_id = stt_last1.node_id
          AND st_last1.datid = stt_last1.datid AND st_last1.reltoastrelid = stt_last1.relid
          AND st_last1.snap_id=stt_last1.snap_id)
        LEFT OUTER JOIN v_snap_stat_tables stt_last2 ON (st_last2.node_id = stt_last2.node_id
          AND st_last2.datid = stt_last2.datid AND st_last2.reltoastrelid = stt_last2.relid
          AND st_last2.snap_id=stt_last2.snap_id)
    WHERE COALESCE(tbl1.growth, tbl2.growth) > 0
    ORDER BY COALESCE(tbl1.growth + tbl1.toastgrowth,0) +
      COALESCE(tbl2.growth + tbl2.toastgrowth,0) DESC) t1
    WHERE rn_growth1 <= topn OR rn_growth2 <= topn;

    r_result RECORD;
BEGIN
    -- Tables stats template
    jtab_tpl := jsonb_build_object(
      'tab_hdr','<table {difftbl}><tr><th rowspan="2">DB</th><th rowspan="2">Tablespace</th><th rowspan="2">Schema</th><th rowspan="2">Table</th><th rowspan="2">I</th><th colspan="6">Table</th><th colspan="6">TOAST</th></tr>'||
      '<tr><th>Size</th><th>Growth</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th><th>Size</th><th>Growth</th><th>Ins</th><th>Upd</th><th>Del</th><th>Upd(HOT)</th></tr>{rows}</table>',
      'row_tpl','<tr {interval1}><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {rowtdspanhdr}>%s</td><td {label} {title1}>1</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
        '<td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
        '</tr><tr {interval2}><td {label} {title2}>2</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td>'||
        '<td {value}>%s</td><td {value}>%s</td><td {value}>%s</td><td {value}>%s</td></tr>'||
        '<tr style="visibility:collapse"></tr>');
    -- apply settings to templates
    jtab_tpl := jsonb_replace(jreportset #> ARRAY['htbl'], jtab_tpl);

    -- Reporting table stats
    FOR r_result IN c_tbl_stats LOOP
        report := report||format(
            jtab_tpl #>> ARRAY['row_tpl'],
            r_result.dbname,
            r_result.tablespacename,
            r_result.schemaname,
            r_result.relname,
            r_result.relsize1,
            r_result.growth1,
            r_result.n_tup_ins1,
            r_result.n_tup_upd1,
            r_result.n_tup_del1,
            r_result.n_tup_hot_upd1,
            r_result.toastrelsize1,
            r_result.toastgrowth1,
            r_result.toastn_tup_ins1,
            r_result.toastn_tup_upd1,
            r_result.toastn_tup_del1,
            r_result.toastn_tup_hot_upd1,
            r_result.relsize2,
            r_result.growth2,
            r_result.n_tup_ins2,
            r_result.n_tup_upd2,
            r_result.n_tup_del2,
            r_result.n_tup_hot_upd2,
            r_result.toastrelsize2,
            r_result.toastgrowth2,
            r_result.toastn_tup_ins2,
            r_result.toastn_tup_upd2,
            r_result.toastn_tup_del2,
            r_result.toastn_tup_hot_upd2
        );
    END LOOP;

    IF report != '' THEN
        report := replace(jtab_tpl #>> ARRAY['tab_hdr'],'{rows}',report);
    END IF;

    RETURN  report;
END;
$$ LANGUAGE plpgsql;
