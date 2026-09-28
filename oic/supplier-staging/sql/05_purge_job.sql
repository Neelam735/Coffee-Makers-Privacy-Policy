-- Optional: removes bank details from finished records every night at 02:00 (database time zone).
BEGIN
   DBMS_SCHEDULER.create_job(
      job_name        => 'XX_SUPPLIER_STG_PURGE',
      job_type        => 'PLSQL_BLOCK',
      job_action      => 'DECLARE n NUMBER; BEGIN xx_supplier_stg_pkg.purge_sensitive(7, n); COMMIT; END;',
      start_date      => SYSTIMESTAMP,
      repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
      enabled         => TRUE);
END;
/
