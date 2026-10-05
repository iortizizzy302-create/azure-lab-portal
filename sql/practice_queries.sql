-- Practice queries for the Azure portal Query editor (SQL database > Query editor)

-- 1. Every out-of-range result, newest first
SELECT s.accession_no, cl.name AS client, c.test_name, r.result_value, c.ref_low, c.ref_high,
       CASE WHEN r.result_value < c.ref_low THEN 'L' ELSE 'H' END AS flag
FROM test_results r
JOIN test_catalog c ON c.test_code = r.test_code
JOIN samples s      ON s.sample_id = r.sample_id
JOIN clients cl     ON cl.client_id = s.client_id
WHERE r.result_value < c.ref_low OR r.result_value > c.ref_high
ORDER BY r.resulted_at DESC;

-- 2. Abnormal rate per test
SELECT c.test_code, c.test_name,
       COUNT(*) AS results,
       SUM(CASE WHEN r.result_value NOT BETWEEN c.ref_low AND c.ref_high THEN 1 ELSE 0 END) AS abnormal,
       CAST(100.0 * SUM(CASE WHEN r.result_value NOT BETWEEN c.ref_low AND c.ref_high THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1)) AS pct_abnormal
FROM test_results r
JOIN test_catalog c ON c.test_code = r.test_code
GROUP BY c.test_code, c.test_name
ORDER BY pct_abnormal DESC;

-- 3. Turnaround time: received -> resulted, per client
SELECT cl.name, AVG(DATEDIFF(HOUR, s.received_on, r.resulted_at)) AS avg_hours
FROM samples s
JOIN clients cl     ON cl.client_id = s.client_id
JOIN test_results r ON r.sample_id = s.sample_id
GROUP BY cl.name;

-- 4. Samples still waiting on results
SELECT s.accession_no, cl.name, s.received_on, DATEDIFF(DAY, s.received_on, GETDATE()) AS days_waiting
FROM samples s JOIN clients cl ON cl.client_id = s.client_id
WHERE s.status <> 'Complete';
