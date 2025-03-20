USE ROLE ACCOUNTADMIN;
USE DATABASE  frostbyte_tasty_bytes;
USE SCHEMA raw_customer;
CREATE OR REPLACE EXTERNAL VOLUME vol_tastybytes_truckreviews
    STORAGE_LOCATIONS =
        (
            (
                NAME = 'reviews-s3-volume'
                STORAGE_PROVIDER = 'S3'
                STORAGE_BASE_URL = 's3://jnanreviews'
                STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<aws-account-id>:role/<snow_role>' --ex:snow_s3_access_role 
                STORAGE_AWS_EXTERNAL_ID = 'RJB12004_SFCRole=4_zSAasUofMUwWxe/Hk98JqRTv2T4=' 
            )
            
        )ALLOW_WRITES=true; 

-- Create Iceberg Tables to track metadata 
CREATE OR REPLACE ICEBERG TABLE iceberg_truck_reviews
        (
        source_name VARCHAR,
        quarter varchar,
        order_id BIGINT,
        truck_id INT,
        language VARCHAR, 
        review VARCHAR,
        primary_city VARCHAR,
        customer_id varchar,
        year date,
        month date,
        truck_brand VARCHAR,
        review_date date
        )
        CATALOG = 'SNOWFLAKE'
        EXTERNAL_VOLUME = 'vol_tastybytes_truckreviews'
        BASE_LOCATION = 'reviews-s3-volume'; 


-- Insert  Metadata from External Files 
INSERT INTO iceberg_truck_reviews
(
        source_name,
        quarter,
        order_id,
        truck_id,
        language, 
        review,
        primary_city ,
        customer_id ,
        year ,
        month ,
        truck_brand ,
        review_date 
)
SELECT 
       SPLIT_PART(METADATA$FILENAME, '/', 4) as source_name,
       CONCAT(SPLIT_PART(METADATA$FILENAME, '/', 2),'/' ,SPLIT_PART(METADATA$FILENAME, '/', 3)) as quarter,
       $1 as order_id,
       $2 as truck_id,
       $3 as language,
       $5 as review,
       $6 as primary_city, 
       $7 as customer_id,
       $8 as year,
       $9 as month,
       $10 as truck_brand,
      DATEADD(HOUR, (ROW_NUMBER() OVER(ORDER BY seq8())-3), to_date('01-11-2022','dd-mm-yyyy')) as review_date
FROM @stg_truck_reviews 
(FILE_FORMAT => 'FF_CSV',
PATTERN => '.*reviews.*[.]csv') 
;


-- Create a view on the Iceberg Reviews, and run Cortex AI to extract Sentiment
USE SCHEMA analytics;

-- We have non-english reviews from global customers
SELECT order_id, quarter, truck_id, language, source_name, primary_city, truck_brand , review, review_date from frostbyte_tasty_bytes.raw_customer.iceberg_truck_reviews  where language !='en' limit 1;

-- Snowflake Cortex makes it easy for us to translate and extract sentiment out of unstructured data
CREATE OR REPLACE VIEW  frostbyte_tasty_bytes.analytics.product_unified_reviews as             
    SELECT order_id, quarter, truck_id, language, source_name, primary_city, truck_brand , snowflake.cortex.sentiment(review) , review_date as final_review from frostbyte_tasty_bytes.raw_customer.iceberg_truck_reviews  where language='en'
    UNION    
    SELECT order_id, quarter, truck_id, language, source_name, primary_city, truck_brand , snowflake.cortex.sentiment(snowflake.cortex.translate(review,language,'en')), review_date as final_review from frostbyte_tasty_bytes.raw_customer.iceberg_truck_reviews where language !='en';


-- Sentiment Grouped By City and Brand 

CREATE OR REPLACE VIEW  frostbyte_tasty_bytes.analytics.product_sentiment AS 
SELECT primary_city, truck_brand, avg(snowflake.cortex.sentiment(final_review)) as review_sentiment 
FROM frostbyte_tasty_bytes.analytics.product_unified_reviews
group by primary_city, truck_brand;

select * from frostbyte_tasty_bytes.analytics.product_sentiment limit 10;