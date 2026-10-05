-- Azure SQL (T-SQL) version of the schema the app creates on first start.
-- You don't need to run this; the app does it. It's here to read and to
-- run by hand in the Azure portal Query editor if you want to rebuild.

CREATE TABLE clients (
    client_id     INT PRIMARY KEY,
    name          NVARCHAR(100) NOT NULL,
    account_no    VARCHAR(20)  NOT NULL,
    contact_email VARCHAR(120)
);

CREATE TABLE test_catalog (
    test_code     VARCHAR(8) PRIMARY KEY,
    test_name     NVARCHAR(60) NOT NULL,
    units         VARCHAR(12),
    ref_low       DECIMAL(9,2) NOT NULL,
    ref_high      DECIMAL(9,2) NOT NULL,
    display_order INT NOT NULL
);

CREATE TABLE samples (
    sample_id     INT PRIMARY KEY,
    client_id     INT NOT NULL REFERENCES clients(client_id),
    accession_no  VARCHAR(20) NOT NULL,
    subject_name  NVARCHAR(60),
    sample_type   VARCHAR(20),
    collected_on  DATE,
    received_on   DATE,
    status        VARCHAR(12)
);

CREATE TABLE test_results (
    result_id     INT IDENTITY(1,1) PRIMARY KEY,
    sample_id     INT NOT NULL REFERENCES samples(sample_id),
    test_code     VARCHAR(8) NOT NULL REFERENCES test_catalog(test_code),
    result_value  DECIMAL(9,2) NOT NULL,
    resulted_at   DATETIME2
);

CREATE INDEX ix_samples_client ON samples(client_id);
CREATE INDEX ix_results_sample ON test_results(sample_id);

-- To start over:
-- DROP TABLE test_results; DROP TABLE samples; DROP TABLE test_catalog; DROP TABLE clients;
