/**************************************************************************
* Copyright 2016 Observational Health Data Sciences AND Informatics (OHDSI)
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may NOT use this file except IN compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to IN writing, software
* distributed under the License is distributed ON an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*
* Authors: Anna Ostropolets, Timur Vakhitov
* Date: 2018
**************************************************************************/

/*
Prerequisites:
1. Get the latest file from source, name it class_drugs_scraper. The file should contain class code, class name, additional information.
For example, for ATC the file will be created in the following manner:
SELECT id, atc_code AS class_code, atc_name AS class_name, ddd, u, adm_r, note, description, ddd_description
FROM atc_drugs_scraper;
2. Prepare input tables (drug_concept_stage, internal_relationship_stage, relationship_to_concept)
according to the general rules for drug vocabularies
3. Prepare the following tables:
- reference (represents the original code and concantinated code and its drug forms in RxNorm format)
- class_to_drug_manual (stores manual mappings, i.g. Insulins)
- ambiguous_class_ingredient (class, code, class_name, ingredients of ATC as ing, flag [ing for the main ingredient,with for additional ingredients,excl for those that should be excluded]).
For groups of ingredients (e.g. antibiotics) list all the possible variations
*/


-- 1. Update latest_update field to new date
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.SetLatestUpdate(
	pVocabularyName			=> 'ATC',
	pVocabularyDate			=> (SELECT vocabulary_date FROM sources.rxnatomarchive LIMIT 1),
	pVocabularyVersion		=> (SELECT vocabulary_version FROM sources.rxnatomarchive LIMIT 1),
	pVocabularyDevSchema	        => 'DEV_ATC'
);
END $_$;

-- 2. Truncate all working tables AND remove indices
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE concept_synonym_stage;
TRUNCATE TABLE pack_content_stage;
TRUNCATE TABLE drug_strength_stage;

-- 3. Preliminary work
-- 3.1 CREATE TABLE with combo drugs to be used later
DROP TABLE IF EXISTS  class_1_comb;
CREATE TABLE class_1_comb AS
SELECT *
FROM class_drugs_scraper
WHERE class_name ~ 'comb| and |diphtheria-|meningococcus|excl|derivate|other|with'
  AND length(class_code) = 7
  AND NOT class_name ~ 'decarboxylase inhibitor';

-- 3.2 create a table with aggregated 
/RxE ingredients
DROP TABLE IF EXISTS rx_combo;
CREATE TABLE rx_combo AS
SELECT drug_concept_id,
       string_agg(ingredient_concept_id::varchar, '-' order by ingredient_concept_id) AS i_combo
FROM drug_strength
       JOIN concept ON concept_id = drug_concept_id and
                       concept_class_id IN ('Clinical Drug Form') -- 'Clinical Drug Comp' doesn exist
GROUP BY drug_concept_id
;

-- 3.3 Precise combos (a and b)
DROP TABLE IF EXISTS simple_comb;
CREATE TABLE simple_comb AS
  with ing AS
    (SELECT i.concept_code_1,i.concept_code_2, class_name,precedence,rtc.concept_id_2 AS ing
     FROM class_1_comb
            left JOIN reference using (class_code)
            JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
            JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Ingredient'
            JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
     WHERE class_name ~ ' and '
       AND NOT class_name ~ 'excl|combinations of|derivate|other|with'
    ),
    form AS
      (SELECT i.concept_code_1,rtc.concept_id_2 AS form
       FROM class_1_comb
              left JOIN reference using (class_code)
              JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
              JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Dose Form'
              JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
       WHERE class_name ~ ' and '
         AND NOT class_name ~ 'excl|combinations of|derivate|other|with'
      )
    SELECT DISTINCT i.concept_code_1,i.concept_code_2, class_name, ing,form,precedence
    FROM ing i
           left JOIN form f ON i.concept_code_1 = f.concept_code_1;

-- 3.4 mapping 1 to 1 for those drugs that have ingredients with 2 or more mappings in relationship_to_concept
DROP TABLE IF EXISTS class_combo;
CREATE TABLE class_combo AS
SELECT concept_code_1,
       string_agg(ing::varchar, '-' order by ing) AS i_combo
FROM simple_comb
WHERE concept_code_1 in
      (SELECT concept_code_1
       FROM simple_comb
       WHERE concept_code_2 in
             (SELECT concept_code_2
              FROM (SELECT DISTINCT concept_code_2, ing FROM simple_comb) s
              GROUP BY concept_code_2
              HAVING COUNT(1) = 1)
       GROUP BY concept_code_1
       HAVING COUNT(1) = 2)
GROUP BY concept_code_1
;

INSERT INTO class_combo AS
SELECT concept_code_1,
       string_agg(ing::varchar, '-' order by ing) AS i_combo
FROM simple_comb
WHERE concept_code_1 in
      (SELECT concept_code_1
       FROM simple_comb
       WHERE concept_code_2 in
             (SELECT concept_code_2
              FROM (SELECT DISTINCT concept_code_2, ing FROM simple_comb) s
              GROUP BY concept_code_2
              HAVING COUNT(1) = 1)
       GROUP BY concept_code_1
       HAVING COUNT(1) = 3)
AND class_name LIKE '%, % and %'
GROUP BY concept_code_1
;
-- 3.4.1 create the actual table, start with ATCs with forms
DROP TABLE IF EXISTS class_to_drug_1;
CREATE TABLE class_to_drug_1 AS
SELECT concept_code_1, class_name, c2.concept_id, c2.concept_name, c2.concept_class_id
FROM class_combo
       JOIN simple_comb using (concept_code_1)
       JOIN rx_combo using (i_combo)
       JOIN concept c ON c.concept_id = drug_concept_id
       JOIN concept_relationship cr
            ON concept_id_1 = c.concept_id AND cr.invalid_reason is null AND relationship_id = 'RxNorm has dose form'
              AND concept_id_2 = form
       JOIN concept c2 ON concept_id_1 = c2.concept_id;

-- 3.4.2 insert the ATCs without forms
INSERT INTO class_to_drug_1
SELECT concept_code_1, class_name, c.concept_id, c.concept_name, c.concept_class_id
FROM class_combo
       JOIN simple_comb using (concept_code_1)
       JOIN rx_combo using (i_combo)
       JOIN concept c ON c.concept_id = drug_concept_id
WHERE concept_code_1 NOT IN (SELECT concept_code_1 FROM class_to_drug_1)
  AND concept_code_1 NOT like '% %'
;

-- 3.4.3 introducing precedence
INSERT INTO class_to_drug_1
with class_comb AS
       (with hold AS (SELECT *
                      FROM simple_comb s
                      WHERE NOT exists(SELECT 1
                                       FROM simple_comb s2
                                       WHERE s2.concept_code_2 = s.concept_code_2 AND s2.precedence > 1) -- we hold
         )
         SELECT h.concept_code_1,
                s.class_name,
                case when h.ing > s.ing then s.ing || '-' || h.ing else h.ing || '-' || s.ing end AS i_combo,
                h.form
         FROM hold h
                JOIN simple_comb s ON h.concept_code_1 = s.concept_code_1 AND h.ing != s.ing
         WHERE h.concept_code_1 NOT IN (SELECT concept_code_1 FROM class_to_drug_1))
SELECT concept_code_1, class_name, c.concept_id, c.concept_name, c.concept_class_id
FROM class_comb
       JOIN rx_combo using (i_combo)
       JOIN concept c ON c.concept_id = drug_concept_id
       JOIN concept_relationship cr
            ON concept_id_1 = c.concept_id AND cr.invalid_reason is null AND relationship_id = 'RxNorm has dose form'
              AND concept_id_2 = form
       JOIN concept c2 ON concept_id_2 = c2.concept_id
;
INSERT INTO class_to_drug_1
with class_comb AS
       (with hold AS (SELECT *
                      FROM simple_comb s
                      WHERE NOT exists(SELECT 1
                                       FROM simple_comb s2
                                       WHERE s2.concept_code_2 = s.concept_code_2 AND s2.precedence > 1) -- we hold
         )
         SELECT h.concept_code_1,
                s.class_name,
                case when h.ing > s.ing then s.ing || '-' || h.ing else h.ing || '-' || s.ing end AS i_combo,
                h.form
         FROM hold h
                JOIN simple_comb s ON h.concept_code_1 = s.concept_code_1 AND h.ing != s.ing
         WHERE h.concept_code_1 NOT IN (SELECT concept_code_1 FROM class_to_drug_1))
SELECT concept_code_1, class_name, c.concept_id, c.concept_name, c.concept_class_id
FROM class_comb
       JOIN rx_combo using (i_combo)
       JOIN concept c ON c.concept_id = drug_concept_id
WHERE concept_code_1 NOT like '% %' --w/o forms
;
					
 -- temporary solution for wierd ATCs that got mapped incorrectly
DELETE
FROM class_to_drug_1
WHERE class_name like '%,%and%'
  AND class_name NOT like '%,%,%and%'
  AND NOT class_name ~* 'comb|other|whole root|selective'
  AND concept_name NOT like '% / % / %';
					
-- 3.5 usual combos (a, combinations)
DROP TABLE IF EXISTS verysimple_comb;
CREATE TABLE verysimple_comb AS
  with ing AS
    (SELECT i.concept_code_1,i.concept_code_2, class_name,rtc.concept_id_2 AS ing, 'ing' AS flag
     FROM class_1_comb
            left JOIN reference using (class_code)
            JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
            JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Ingredient'
            JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
     WHERE class_name ~ 'comb'
       AND NOT class_name ~ 'excl| AND |combinations of|derivate|other|with'
    ),
    form AS
      (SELECT i.concept_code_1,rtc.concept_id_2 AS form
       FROM class_1_comb
              left JOIN reference using (class_code)
              JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
              JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Dose Form'
              JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
       WHERE class_name ~ 'comb'
         AND NOT class_name ~ 'excl| AND |combinations of|derivate|other|with'
      ),
    addit AS
      (SELECT i.concept_code_1, i.concept_code_2, class_name, rtc.concept_id_2 AS ing, 'with' AS flag
       FROM class_1_comb a
              left JOIN reference r using (class_code)
              JOIN concept c ON regexp_replace(c.concept_code, '..$', '') = regexp_replace(a.class_code, '..$', '') and
                                c.concept_class_id = 'ATC 5th'
              JOIN internal_relationship_stage i ON coalesce(r.concept_code, class_code) = concept_code_1
              JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND d.concept_class_id = 'Ingredient'
              JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
      )
    SELECT DISTINCT i.concept_code_1,i.concept_code_2, class_name, ing,form, flag
    FROM (SELECT *
          FROM ing
          union all
          SELECT *
          FROM addit) i
           left JOIN form f ON i.concept_code_1 = f.concept_code_1
    order by i.concept_code_1;

DROP TABLE IF EXISTS class_to_drug_2;
CREATE TABLE class_to_drug_2 AS
  with secondary_table AS (
    SELECT a.concept_id, a.concept_name,a.concept_class_id,a.vocabulary_id, c.concept_id_2,r.i_combo
    FROM rx_combo r
           JOIN concept a ON r.drug_concept_id = a.concept_id
           JOIN concept_relationship c ON c.concept_id_1 = a.concept_id
    WHERE a.concept_class_id = 'Clinical Drug Form'
      AND a.vocabulary_id like 'RxNorm%'--temporary remove RXE
      AND a.invalid_reason is null
      AND relationship_id = 'RxNorm has dose form'
      AND c.invalid_reason is null
    ),
    primary_table AS (
      SELECT v.concept_code_1,
             v.form,
             v.class_name,
             case
               when v.ing > v2.ing then cast(v2.ing AS varchar) || '-' || cast(v.ing AS varchar)
               else cast(v.ing AS varchar) || '-' || cast(v2.ing AS varchar) end AS class_combo
      FROM verysimple_comb v
             JOIN verysimple_comb v2 ON v.concept_code_1 = v2.concept_code_1 AND v.flag = 'ing' AND v2.flag = 'with'
      WHERE v.ing != v2.ing)
    SELECT DISTINCT p.concept_code_1, class_name, s.concept_id, s.concept_name, s.concept_class_id
    FROM primary_table p
           JOIN secondary_table s
                ON s.concept_id_2 = p.form
                  AND s.i_combo = p.class_combo
;

INSERT INTO class_to_drug_2
with primary_table AS (
  SELECT v.concept_code_1,
         v.form,
         v.class_name,
         case
           when v.ing > v2.ing then cast(v2.ing AS varchar) || '-' || cast(v.ing AS varchar)
           else cast(v.ing AS varchar) || '-' || cast(v2.ing AS varchar) end AS class_combo
  FROM verysimple_comb v
         JOIN verysimple_comb v2 ON v.concept_code_1 = v2.concept_code_1 AND v.flag = 'ing' AND v2.flag = 'with'
  WHERE v.ing != v2.ing)
SELECT DISTINCT p.concept_code_1, class_name, c.concept_id, c.concept_name, c.concept_class_id
FROM primary_table p
       JOIN rx_combo r ON p.class_combo = r.i_combo
       JOIN concept c ON c.concept_id = r.drug_concept_id AND c.concept_class_id = 'Clinical Drug Form' and
                         c.vocabulary_id like 'RxNorm%'
WHERE p.concept_code_1 NOT like '% %'--exclude classes with known forms
;

-- 3.6 ATC combos with exclusions
DROP TABLE IF EXISTS compl_combo;
CREATE TABLE compl_combo AS
  with hold AS (
    SELECT *
    FROM ambiguous_class_ingredient d
           JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'ing' --we hold
    WHERE NOT exists(SELECT 1
                     FROM ambiguous_class_ingredient d2
                     WHERE d.class_code = d2.class_code
                       AND d.ing = d2.ing
                       AND precedence > 1) -- we hold, exclude multiple for now
    ),
    excl AS (
      SELECT *
      FROM ambiguous_class_ingredient d
             JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'excl' --we exclude
      ),
    additional AS (
      SELECT *
      FROM ambiguous_class_ingredient d
             JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'with' --we add
      )
    SELECT DISTINCT r.concept_code  AS concept_code_1,
                    h.class_name,
                    drug_concept_id AS concept_id,
                    concept_name,
                    concept_class_id
    FROM hold h
           JOIN reference r ON r.class_code = h.class_code
           left JOIN additional a ON h.class_code = a.class_code
           left JOIN excl e ON h.class_code = e.class_code
           JOIN rx_combo ON i_combo ~ cast(h.concept_id_2 AS varchar) AND i_combo like '%-%'
           JOIN concept c ON c.concept_id = drug_concept_id
    WHERE (a.class_code is NOT null AND i_combo ~ cast(a.concept_id_2 AS varchar))
       or (e.class_code is NOT null AND NOT i_combo ~ cast(e.concept_id_2 AS varchar))
;

-- 3.6.1 with no excluded
INSERT INTO compl_combo
with hold AS (
  SELECT *
  FROM ambiguous_class_ingredient d
         JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'ing' --we hold
  WHERE NOT exists(SELECT 1
                   FROM ambiguous_class_ingredient d2
                   WHERE d.class_code = d2.class_code
                     AND d.ing = d2.ing
                     AND precedence > 1) -- we hold, exclude multiple for now
),
     excl AS (
       SELECT *
       FROM ambiguous_class_ingredient d
              JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'excl' --we exclude
     ),
     additional AS (
       SELECT *
       FROM ambiguous_class_ingredient d
              JOIN relationship_to_concept ON concept_code_1 = ing AND flag = 'with' --we add
     )

SELECT DISTINCT r.concept_code  AS concept_code_1,
                h.class_name,
                drug_concept_id AS concept_id,
                concept_name,
                concept_class_id
FROM hold h
       JOIN reference r ON r.class_code = h.class_code
       JOIN additional a ON h.class_code = a.class_code
       left JOIN excl e ON e.class_code = h.class_code
       JOIN rx_combo ON i_combo ~ cast(h.concept_id_2 AS varchar) AND i_combo ~ cast(a.concept_id_2 AS varchar) and
                        i_combo like '%-%'
       JOIN concept c ON c.concept_id = drug_concept_id
WHERE e.class_name is null
;
-- 3.6.2 with
DROP TABLE IF EXISTS class_to_drug_3;
CREATE TABLE class_to_drug_3 AS
SELECT c.*
FROM compl_combo c
       JOIN internal_relationship_stage i ON i.concept_code_1 = c.concept_code_1
       JOIN relationship_to_concept rtc ON rtc.concept_code_1 = i.concept_code_2
       JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id
  AND relationship_id = 'RxNorm has dose form' AND cr.invalid_reason is null
WHERE cr.concept_id_2 = rtc.concept_id_2
  AND class_name like '%with%'
;
-- 3.6.3 inserting everything that goes without a form
INSERT INTO class_to_drug_3
SELECT *
FROM compl_combo
WHERE concept_code_1 NOT like '% %'
  AND class_name like '%with%';

-- 3.6.4 start removing incorrectly assigned combo based ON WHO rank
-- zero rank (no official rank is present)
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'M03BA73|M03BA72|N02AC74|M03BB72|N02BB52|M03BB73|M09AA72|N02AB72|N02BB72|N02BA77'
  AND concept_name ~*
      'Salicylamide|Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Methadone|etamizole|Ergotamine'
;
--starts the official rank
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BB74'
  AND concept_name ~* 'Salicylamide|Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BB51'
  AND concept_name ~* 'Salicylamide|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BA75'
  AND concept_name ~* 'Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BB71'
  AND concept_name ~* 'Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BA71'
  AND concept_name ~* 'Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02BE71'
  AND concept_name ~* 'Dipyrocetyl|Bucetin|Phenacetin'
;
DELETE
FROM class_to_drug_3
WHERE concept_code_1 ~ 'N02'
  AND concept_name ~ 'Codeine'
  AND NOT class_name ~ 'codeine';

DELETE
FROM class_to_drug_3
WHERE concept_id IN --removing duplicates
      (SELECT concept_id FROM class_to_drug_1);

-- 3.7 class codes of type a+b excl. c
DROP TABLE IF EXISTS class_to_drug_4;
CREATE TABLE class_to_drug_4 AS
SELECT c.*
FROM compl_combo c
       JOIN internal_relationship_stage i ON i.concept_code_1 = c.concept_code_1
       JOIN relationship_to_concept rtc ON rtc.concept_code_1 = i.concept_code_2
       JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id
  AND relationship_id = 'RxNorm has dose form' AND cr.invalid_reason is null
WHERE cr.concept_id_2 = rtc.concept_id_2
  AND class_name NOT like '%with%'
;

-- 3.7.1 inserting everything that goes without a form
INSERT INTO class_to_drug_4
SELECT *
FROM compl_combo
WHERE concept_code_1 NOT like '% %'
  AND class_name NOT like '%with%';

-- 3.7.2 start removing incorrectly assigned combo based ON WHO rank
-- zero rank
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'M03BA53|M03BA52|N02AC54|M03BB52|M03BB53|N02AB52|N02BB52|N02CA52|N02BA57'
  AND concept_name ~* 'Salicylamide|Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Methadone'
;
--starts the official rank
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BB54|N02BB52|M03BB52'
  AND concept_name ~* 'Salicylamide|Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Ergotamine|Dipyrone'
;
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BA55'
  AND concept_name ~* 'Phenazone|Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Ergotamine|Metamizole'
;
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BB51'
  AND concept_name ~* 'Aspirin|Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Ergotamine|Metamizole'
;
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BA51'
  AND concept_name ~* 'Acetaminophen|Dipyrocetyl|Bucetin|Phenacetin|Ergotamine|Metamizole'
;
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BE51|N02BB53'
  AND concept_name ~* 'Dipyrocetyl|Bucetin|Phenacetin|Ergotamine|Metamizole'
;
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02AC54'
  AND concept_name ~* 'Dipyrone';

DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02'
  AND concept_name ~ 'Codeine'
  AND NOT class_name ~ 'codeine';

DELETE
FROM class_to_drug_4
WHERE concept_id IN --removing duplicates
      (SELECT concept_id FROM class_to_drug_1);

--3.7.3 atenolol AND other diuretics, combinations, one of a kind
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'C07CB53|C07DB01'
  AND concept_name NOT like '%/%/%';
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'C07CB03|C07CB53'
  AND concept_name like '%/%/%';

-- PPI AND aspirin
DELETE
FROM class_to_drug_4
WHERE concept_code_1 ~ 'N02BA51'
  AND concept_name ~* 'Omeprazole|Pantoprazole|Rabeprazol';
							 							  							   
-- 3.8  Simlpe class codes that have dose forms
DROP TABLE IF EXISTS primary_table;
CREATE TABLE primary_table AS
  with ing AS
    (SELECT i.concept_code_1,class_name,rtc.concept_id_2 AS ing
     FROM class_drugs_scraper
            LEFT JOIN reference using (class_code)
            JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
            JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Ingredient'
            JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
              WHERE class_name !~'combination|and|^other| with|mening|diphtheria'
    ),
    form AS
      (SELECT i.concept_code_1,rtc.concept_id_2 AS form
       FROM class_drugs_scraper
              LEFT JOIN reference using (class_code)
              JOIN internal_relationship_stage i ON coalesce(concept_code, class_code) = concept_code_1
              JOIN drug_concept_stage d ON d.concept_code = concept_code_2 AND concept_class_id = 'Dose Form'
              JOIN relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
                WHERE class_name !~'combination| and |^other| with|mening|diphtheria'
      )
    SELECT DISTINCT i.concept_code_1, class_name, ing,form
    FROM ing i
           LEFT JOIN form f ON i.concept_code_1 = f.concept_code_1;

DROP TABLE IF EXISTS class_to_drug_5;
CREATE TABLE class_to_drug_5 AS
  with secondary_table AS (
    SELECT a.concept_id,
           a.concept_name,
           a.concept_class_id,
           a.vocabulary_id,
           c.concept_id_2          AS sform,
           b.ingredient_concept_id AS sing
    FROM concept a
           JOIN drug_strength b ON b.drug_concept_id = a.concept_id
           JOIN concept_relationship c ON c.concept_id_1 = a.concept_id
    WHERE a.concept_class_id = 'Clinical Drug Form'
      AND a.vocabulary_id like 'RxNorm%'--temporary remove RXE
      AND a.invalid_reason is null
      AND relationship_id = 'RxNorm has dose form'
      AND c.invalid_reason is null
      AND NOT exists(SELECT 1
                     FROM drug_strength d
                     WHERE d.drug_concept_id = b.drug_concept_id
                       AND d.ingredient_concept_id != b.ingredient_concept_id) -- excluding combos
    )
    SELECT DISTINCT p.concept_code_1, class_name, s.concept_id, s.concept_name, s.concept_class_id
    FROM primary_table p,
         secondary_table s
    WHERE s.sform = p.form
      AND s.sing = p.ing
;
-- 3.8.1 manually excluded drugs based ON Precise Ingredients
INSERT INTO class_to_drug_5
SELECT 'B02BD11','catridecacog', concept_id, concept_name, concept_class_id
FROM concept
WHERE vocabulary_id like 'RxNorm%' AND concept_name like 'coagulation factor XIII a-subunit (recombinant)%' and
      standard_concept = 'S'
   or concept_id = 35603348 -- the whole hierarchy
;

INSERT INTO class_to_drug_5
SELECT 'B02BD14','susoctocog alfa', concept_id, concept_name, concept_class_id
FROM concept
WHERE vocabulary_id like 'RxNorm%' and
      concept_name like 'antihemophilic factor, porcine B-domain truncated recombinant%' AND standard_concept = 'S'
   or concept_id IN (35603348, 44109089) -- the whole hierarchy
;
DELETE
FROM class_to_drug_5
WHERE concept_code_1 = 'B02BD14'
  AND concept_name like '%Tretten%' --catridecacog
;
DELETE
FROM class_to_drug_5
WHERE class_name = 'amino acids';

-- 3.9 Class codes that do NOT have forms (ingredients only)
DROP TABLE IF EXISTS class_to_drug_6;
CREATE TABLE class_to_drug_6 AS
  with secondary_table AS (
    SELECT a.concept_id, a.concept_name,a.concept_class_id,a.vocabulary_id, b.ingredient_concept_id AS sing
    FROM concept a
           JOIN drug_strength b
                ON b.drug_concept_id = a.concept_id
    WHERE a.concept_class_id = 'Ingredient'
      AND a.invalid_reason is null
      AND a.vocabulary_id = 'RxNorm%'--temporary remove RXE
      AND NOT exists(SELECT 1
                     FROM drug_strength d
                     WHERE d.drug_concept_id = b.drug_concept_id
                       AND d.ingredient_concept_id != b.ingredient_concept_id) -- excluding combos
    )
    SELECT DISTINCT p.concept_code_1, class_name, s.concept_id, s.concept_name, s.concept_class_id
    FROM primary_table p,
         secondary_table s
    WHERE s.sing = p.ing
      AND p.form is null
      AND p.concept_code_1 NOT IN (SELECT concept_code FROM reference WHERE concept_code != class_code)-- exclude drugs that should have forms (will remain unmapped)
      ;

-- 4. Start final assembly, insert one-by-one going from the most precise class (a+b) to the simplest one (a, ingredient)
-- TODO: G03FB|G03AB
-- hardcoded combinations							   

-- 4.1
DROP TABLE IF EXISTS class_to_rx_descendant;
CREATE TABLE class_to_rx_descendant
AS
SELECT DISTINCT substring(concept_code_1, '\w+') AS class_code,
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '1'                              AS order
FROM class_to_drug_1 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND vocabulary_id like 'RxNorm%' AND c.standard_concept = 'S';
-- 4.2.1 
DELETE
FROM class_to_rx_descendant
WHERE class_code ~ 'G03FB|G03AB'
  AND concept_class_id NOT like '%Pack%';
							   
-- 4.2.2 combinations from ATC 4th, need to be fixed afterwards							   
DELETE 
FROM class_to_rx_descendant
WHERE class_name NOT LIKE '% / %'
AND class_code ~ 'S01CB|G03EK|G03CC|D10AA|D07XC|D07XB|D07XA'
;							   

-- 4.3
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '2' AS order
FROM class_to_drug_2 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND c.vocabulary_id like 'RxNorm%' AND c.standard_concept = 'S'
WHERE descendant_concept_id NOT IN (SELECT concept_id FROM class_to_rx_descendant);

-- 4.4
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '3' AS order
FROM class_to_drug_3 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND c.vocabulary_id like 'RxNorm%' AND c.standard_concept = 'S'
WHERE descendant_concept_id NOT IN (SELECT concept_id FROM class_to_rx_descendant);

-- 4.5
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '4' AS order
FROM class_to_drug_4 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND c.vocabulary_id like 'RxNorm%' AND c.standard_concept = 'S'
WHERE descendant_concept_id NOT IN (SELECT concept_id FROM class_to_rx_descendant);

--4.6
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '5' AS order
FROM class_to_drug_5 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND c.vocabulary_id like 'RxNorm%' AND c.standard_concept = 'S'
       JOIN drug_strength d ON d.drug_concept_id = c.concept_id
WHERE descendant_concept_id NOT IN (SELECT concept_id FROM class_to_rx_descendant)
  AND NOT exists
  (SELECT 1
   FROM concept c2
          JOIN devv5.concept_ancestor ca2
               ON ca2.ancestor_concept_id = c2.concept_id AND c2.concept_class_id = 'Ingredient' 
               AND c2.vocabulary_id like 'RxNorm%'
   WHERE ca2.descendant_concept_id = d.drug_concept_id
     AND c2.concept_id != d.ingredient_concept_id) -- excluding combos
;
-- 4.7 working with packs
with a AS (
  SELECT DISTINCT a.*,
                  c.concept_id AS pack_id,
                  d.drug_concept_id,
                  d.ingredient_concept_id
  FROM class_to_drug_5 a
         JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
         JOIN concept c ON c.concept_id = descendant_concept_id AND c.vocabulary_id like 'RxNorm%'
    AND c.standard_concept = 'S' AND c.concept_class_id IN ('Clinical Pack ', 'Branded Pack')
         JOIN concept_relationship cr
              ON cr.concept_id_1 = c.concept_id AND cr.invalid_reason is null AND cr.relationship_id = 'Contains'
         JOIN drug_strength d ON d.drug_concept_id = cr.concept_id_2
  WHERE descendant_concept_id NOT IN (SELECT concept_id
                                      FROM сlass_to_rx_descendant)
),
     b AS (
       SELECT DISTINCT concept_code_1,
                       class_name,
                       concept_id,
                       concept_name,
                       concept_class_id,
                       pack_id,
                       string_agg(ingredient_concept_id::varchar, '-' order by ingredient_concept_id) AS i_combo
       FROM a
       GROUP BY concept_code_1,class_name,concept_id,concept_name,concept_class_id, pack_id
     ),
     c AS (
       SELECT DISTINCT b.concept_code_1,
                       b.class_name,
                       b.concept_id,
                       b.concept_name,
                       b.concept_class_id,
                       b.i_combo,
                       pack_id,
                       string_agg(ca.ancestor_concept_id:: varchar, '-' order by ca.ancestor_concept_id) AS i_combo_2
       FROM b
              JOIN devv5.concept_ancestor ca ON b.concept_id = ca.descendant_concept_id
              JOIN concept c ON c.concept_id = ca.ancestor_concept_id AND c.concept_class_id = 'Ingredient'
       GROUP BY b.concept_code_1, b.class_name, b.concept_id, b.concept_name, b.concept_class_id, b.i_combo,
                ca.descendant_concept_id,pack_id
     )
INSERT
INTO class_to_rx_descendant
(class_code, class_name, concept_id, concept_name, concept_code, concept_class_id, "order")
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                pack_id,
                cc.concept_name,
                cc.concept_code,
                cc.concept_class_id,
                '5'
FROM c
       JOIN concept cc ON cc.concept_id = pack_id
WHERE i_combo = i_combo_2
   OR i_combo = i_combo_2 || '-' || i_combo_2
;

-- 4.8
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '6' AS order
FROM class_to_drug_6 a
       JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
       JOIN concept c
            ON c.concept_id = descendant_concept_id AND c.vocabulary_id LIKE 'RxNorm%' AND c.standard_concept = 'S'
       JOIN drug_strength d ON d.drug_concept_id = c.concept_id
WHERE descendant_concept_id NOT IN (SELECT concept_id FROM class_to_rx_descendant)
  AND NOT exists
  (SELECT 1
   FROM concept c2
          JOIN devv5.concept_ancestor ca2
               ON ca2.ancestor_concept_id = c2.concept_id AND c2.concept_class_id = 'Ingredient' 
               AND c2.vocabulary_id LIKE 'RxNorm%'
   WHERE ca2.descendant_concept_id = d.drug_concept_id
     AND c2.concept_id != d.ingredient_concept_id) -- excluding combos
;

-- 4.9 working with packs
WITH a AS (
  SELECT DISTINCT a.*,
                  c.concept_id AS pack_id,
                  d.drug_concept_id,
                  d.ingredient_concept_id
  FROM class_to_drug_6 a
         JOIN devv5.concept_ancestor ON ancestor_concept_id = a.concept_id
         JOIN concept c ON c.concept_id = descendant_concept_id AND c.vocabulary_id LIKE 'RxNorm%'
    AND c.standard_concept = 'S' AND c.concept_class_id IN ('Clinical Pack ', 'Branded Pack')
         JOIN concept_relationship cr
              ON cr.concept_id_1 = c.concept_id AND cr.invalid_reason is null AND cr.relationship_id = 'Contains'
         JOIN drug_strength d ON d.drug_concept_id = cr.concept_id_2
  WHERE descendant_concept_id NOT IN (SELECT concept_id
                                      FROM сlass_to_rx_descendant)
),
     b AS (
       SELECT DISTINCT concept_code_1,
                       class_name,
                       concept_id,
                       concept_name,
                       concept_class_id,
                       pack_id,
                       string_agg(ingredient_concept_id::varchar, '-' ORDER BY ingredient_concept_id) AS i_combo
       FROM a
       GROUP BY concept_code_1,class_name,concept_id,concept_name,concept_class_id, pack_id
     ),
     c AS (
       SELECT DISTINCT b.concept_code_1,
                       b.class_name,
                       b.concept_id,
                       b.concept_name,
                       b.concept_class_id,
                       b.i_combo,
                       pack_id,
                       string_agg(ca.ancestor_concept_id:: varchar, '-' ORDER BY ca.ancestor_concept_id) AS i_combo_2
       FROM b
              JOIN devv5.concept_ancestor ca ON b.concept_id = ca.descendant_concept_id
              JOIN concept c ON c.concept_id = ca.ancestor_concept_id AND c.concept_class_id = 'Ingredient'
       GROUP BY b.concept_code_1, b.class_name, b.concept_id, b.concept_name, b.concept_class_id, b.i_combo,
                ca.descendant_concept_id,pack_id
     )
INSERT INTO class_to_rx_descendant
(class_code, class_name, concept_id, concept_name, concept_code, concept_class_id, "order")
SELECT DISTINCT substring(concept_code_1, '\w+'),
                class_name,
                pack_id,
                cc.concept_name,
                cc.concept_code,
                cc.concept_class_id,
                '6'
FROM c
       JOIN concept cc ON cc.concept_id = pack_id
WHERE i_combo = i_combo_2
   or i_combo = i_combo_2 || '-' || i_combo_2
;

-- 4.10
DELETE
FROM class_to_rx_descendant
WHERE class_name LIKE '%insulin%';
INSERT INTO class_to_rx_descendant
SELECT DISTINCT class_code,
                class_name,
                c.concept_id,
                c.concept_name,
                c.concept_code,
                c.concept_class_id,
                '7' AS order
FROM class_to_drug_manual m
       JOIN devv5.concept_ancestor ca ON ca.ancestor_concept_id = m.concept_id
       JOIN concept c ON c.concept_id = ca.descendant_concept_id
       JOIN drug_strength d ON d.drug_concept_id = c.concept_id
;

-- 4.11 fix packs
INSERT INTO class_to_rx_descendant
SELECT DISTINCT substring(concept_code_1, '\w+'), class_name,c.concept_id, c.concept_name, c.concept_code, c.concept_class_id, 1
FROM class_to_drug_1 f
       JOIN devv5.concept_ancestor ca ON ca.ancestor_concept_id = cast(f.concept_id AS int)
       JOIN devv5.concept c ON c.concept_id = descendant_concept_id AND c.concept_class_id LIKE '%Pack%'
WHERE f.concept_code_1 ~ 'G03FB|G03AB'; -- packs

-- 4.12
DELETE
FROM class_to_rx_descendant
WHERE class_code ~ 'G03FB|G03AB'
  AND concept_class_id IN ('Clinical Drug Form', 'Ingredient');

DELETE
FROM class_to_rx_descendant
WHERE class_name like '%and estrogen%' -- if there are regular estiol/estradiol/EE
  AND concept_id IN (SELECT concept_id FROM сlass_to_rx_descendant GROUP BY concept_id HAVING COUNT(1) > 1);

-- 4.13 temporary solution (same as before)
DELETE
FROM class_to_rx_descendant
WHERE class_name like '%,%,%and%'
  AND NOT class_name ~* 'comb|other|whole root|selective'
  AND concept_name NOT like '%/%/%/%';

DELETE
FROM class_to_rx_descendant
WHERE class_name like '%,%and%'
  AND class_name NOT like '%,%,%and%'
  AND NOT class_name ~* 'comb|other|whole root|selective'
  AND concept_name NOT like '% / % / %';
							   
DELETE
FROM class_to_rx_descendant
WHERE class_name NOT LIKE '% / %'
AND class_code ~ 'S01CB|G03EK|G03CC|D10AA|D07XC|D07XB|D07XA'
;							   							   

-- 4.14 repeate all the steps to get the table without ancestor (just the basic entities)
DROP TABLE IF EXISTS class_to_drug;
CREATE TABLE class_to_drug
AS
SELECT DISTINCT substring(concept_code_1, '\w+') AS class_code,
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '1' AS order
FROM class_to_drug_1 a
;
INSERT INTO class_to_drug
SELECT DISTINCT substring(concept_code_1, '\w+'),
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '2' AS order
FROM class_to_drug_2 a
WHERE concept_code_1 NOT IN
      (SELECT class_code FROM class_to_drug)
  AND a.concept_id NOT IN
      (SELECT concept_id FROM class_to_drug)
;
INSERT INTO class_to_drug
SELECT DISTINCT substring(concept_code_1, '\w+'),
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '3' AS order
FROM class_to_drug_3 a
WHERE concept_code_1 NOT IN
      (SELECT class_code FROM class_to_drug)
;
INSERT INTO class_to_drug
SELECT DISTINCT substring(concept_code_1, '\w+'),
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '4' AS order
FROM class_to_drug_4 a
WHERE concept_code_1 NOT IN
      (SELECT class_code FROM class_to_drug);

INSERT INTO class_to_drug
SELECT DISTINCT substring(concept_code_1, '\w+'),
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '5' AS order
FROM class_to_drug_5 a
WHERE concept_code_1 NOT IN
      (SELECT class_code FROM class_to_drug);

INSERT INTO class_to_drug
SELECT DISTINCT substring(concept_code_1, '\w+'),
                a.class_name,
                a.concept_id,
                a.concept_name,
                a.concept_code_1,
                a.concept_class_id,
                '6' AS order
FROM class_to_drug_6 a
WHERE concept_code_1 NOT IN
      (SELECT class_code FROM class_to_drug);

DELETE
FROM class_to_drug
WHERE class_name like '%insulin%';
INSERT INTO class_to_drug
SELECT DISTINCT class_code,
                m.class_name,
                m.concept_id,
                m.concept_name,
                c.concept_code,
                m.concept_class_id,
                '7' AS order
FROM class_to_drug_manual m
       JOIN concept c using (concept_id)
;

INSERT INTO class_to_drug
SELECT substring(concept_code_1, '\w+'), f.class_name, c.concept_id, c.concept_name, c.concept_code, c.concept_class_id, f.order
FROM class_to_drug f
       JOIN devv5.concept_ancestor ca
            ON ca.ancestor_concept_id = f.concept_id
       JOIN devv5.concept c ON c.concept_id = descendant_concept_id AND c.concept_class_id LIKE '%Pack%'
WHERE class_code ~ 'G03FB|G03AB'; -- packs

DELETE
FROM class_to_drug
WHERE class_code ~ 'G03FB|G03AB'
  AND concept_class_id IN ('Clinical Drug Form', 'Ingredient');

DELETE 
FROM class_to_drug
WHERE class_name NOT LIKE '% / %'
AND class_code ~ 'S01CB|G03EK|G03CC|D10AA|D07XC|D07XB|D07XA'
;							   

DELETE
FROM class_to_drug
WHERE class_name like '%and estrogen%' -- if there are regular estiol/estradiol/EE
  AND concept_id IN (SELECT concept_id FROM class_to_drug GROUP BY concept_id HAVING COUNT(1) > 1);


--5. Get tables for see what is missing
--5.1 Check new class codes that should be worked out
SELECT *
FROM class_drugs_scraper
WHERE class_code NOT IN
      (SELECT concept_code FROM concept WHERE vocabulary_id = 'ATC');
--5.2 Take a look at new standard ingredients that did not exist before the last ATC release
SELECT *
FROM concept
WHERE vocabulary_id in ('RxNorm', 'RxNorm Extension')
  AND concept_class_id = 'Ingredient'
  AND standard_concept = 'S'
  AND valid_start_date > (select latest_update
                          from devv5.vocabulary_conversion
                          where vocabulary_id_v5 = 'ATC');
--5.3 Take a look at the ATC codes that aren't covered in the release
SELECT *
FROM class_drugs_scraper
WHERE class_code NOT IN (SELECT class_code FROM class_to_drug);


-- 6. Add ATC
-- create temporary table atc_tmp_table
DROP TABLE IF EXISTS  atc_tmp_table;
CREATE UNLOGGED TABLE atc_tmp_table AS
SELECT rxcui,
	code,
	concept_name,
	'ATC' AS vocabulary_id,
	'C' AS standard_concept,
	concept_code,
	concept_class_id
FROM (
	SELECT DISTINCT rxcui,
		code,
		SUBSTR(str, 1, 255) AS concept_name,
		code AS concept_code,
		CASE
			WHEN LENGTH(code) = 1
				THEN 'ATC 1st'
			WHEN LENGTH(code) = 3
				THEN 'ATC 2nd'
			WHEN LENGTH(code) = 4
				THEN 'ATC 3rd'
			WHEN LENGTH(code) = 5
				THEN 'ATC 4th'
			WHEN LENGTH(code) = 7
				THEN 'ATC 5th'
			END AS concept_class_id
	FROM sources.rxnconso
	WHERE sab = 'ATC'
		AND tty IN (
			'PT',
			'IN'
			)
		AND code != 'NOCODE'
	) AS s1;

CREATE INDEX idx_atc_code ON atc_tmp_table (code);
CREATE INDEX idx_atc_ccode ON atc_tmp_table (concept_code);
ANALYZE atc_tmp_table;

-- 7. Add atc_tmp_table to concept_stage
INSERT INTO concept_stage (
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT concept_name,
	'Drug' AS domain_id,
	dv.vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM atc_tmp_table dv,
	vocabulary v
WHERE v.vocabulary_id = dv.vocabulary_id;

-- 8. Create all sorts of relationships to self, RxNorm AND SNOMED
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	relationship_id,
	vocabulary_id_1,
	vocabulary_id_2,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'VA Class to ATC eq' AS relationship_id,
	'VA Class' AS vocabulary_id_1,
	'ATC' AS vocabulary_id_2,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM atc_tmp_table d
JOIN sources.rxnconso r ON r.rxcui = d.rxcui
	AND r.code != 'NOCODE'
JOIN atc_tmp_table e ON r.rxcui = e.rxcui
	AND r.code = e.concept_code
JOIN vocabulary v ON v.vocabulary_id = d.vocabulary_id
WHERE d.concept_class_id LIKE 'VA Class'
	AND e.concept_class_id LIKE 'ATC%'

UNION ALL

-- Cross-link between drug class Chemical Structure AND ATC
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'NDFRT to ATC eq' AS relationship_id,
	'NDFRT' AS vocabulary_id_1,
	'ATC' AS vocabulary_id_2,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM atc_tmp_table d
JOIN sources.rxnconso r ON r.rxcui = d.rxcui
	AND r.code != 'NOCODE'
JOIN atc_tmp_table e ON r.rxcui = e.rxcui
	AND r.code = e.concept_code
JOIN vocabulary v ON v.vocabulary_id = d.vocabulary_id
WHERE d.concept_class_id = 'Chemical Structure'
	AND e.concept_class_id IN (
		'ATC 1st',
		'ATC 2nd',
		'ATC 3rd',
		'ATC 4th'
		)

UNION ALL

-- Cross-link between drug class ATC AND Therapeutic Class
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'NDFRT to ATC eq' AS relationship_id,
	'NDFRT' AS vocabulary_id_1,
	'ATC' AS vocabulary_id_2,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM atc_tmp_table d
JOIN sources.rxnconso r ON r.rxcui = d.rxcui
	AND r.code != 'NOCODE'
JOIN atc_tmp_table e ON r.rxcui = e.rxcui
	AND r.code = e.concept_code
JOIN vocabulary v ON v.vocabulary_id = d.vocabulary_id
WHERE d.concept_class_id LIKE 'Therapeutic Class'
	AND e.concept_class_id LIKE 'ATC%'

UNION ALL

-- Cross-link between drug class SNOMED AND ATC classes (not ATC 5th)
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'SNOMED - ATC eq' AS relationship_id,
	'SNOMED' AS vocabulary_id_1,
	'ATC' AS vocabulary_id_2,
	d.valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept d
JOIN sources.rxnconso r ON r.code = d.concept_code
	AND r.sab = 'SNOMEDCT_US'
	AND r.code != 'NOCODE'
JOIN sources.rxnconso r2 ON r.rxcui = r2.rxcui
	AND r2.sab = 'ATC'
	AND r2.code != 'NOCODE'
JOIN atc_tmp_table e ON r2.code = e.concept_code
	AND e.concept_class_id != 'ATC 5th' -- Ingredients only to RxNorm
WHERE d.vocabulary_id = 'SNOMED'
	AND d.invalid_reason IS NULL

UNION ALL

-- add ATC to RxNorm
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'ATC - RxNorm' AS relationship_id, -- this is one to substitute "NDFRF has ing", is hierarchical AND defines ancestry.
	'ATC' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM atc_tmp_table d
JOIN sources.rxnconso r ON r.rxcui = d.rxcui
	AND r.code != 'NOCODE'
JOIN vocabulary v ON v.vocabulary_id = d.vocabulary_id
JOIN concept e ON r.rxcui = e.concept_code
	AND e.vocabulary_id = 'RxNorm'
	AND e.invalid_reason IS NULL
WHERE d.vocabulary_id = 'ATC'
	AND d.concept_class_id = 'ATC 5th' -- there are some weird 4th level links, LIKE D11AC 'Medicated shampoos' to an RxNorm Dose Form
        AND e.concept_class_id NOT IN ('Ingredient','Precise Ingredient')
UNION ALL

-- Hierarchy inside ATC
SELECT uppr.concept_code AS concept_code_1,
	lowr.concept_code AS concept_code_2,
	'Is a' AS relationship_id,
	'ATC' AS vocabulary_id_1,
	'ATC' AS vocabulary_id_2,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept_stage uppr,
	concept_stage lowr,
	vocabulary v
WHERE (
		(
			LENGTH(uppr.concept_code) IN (
				4,
				5
				)
			AND lowr.concept_code = SUBSTR(uppr.concept_code, 1, LENGTH(uppr.concept_code) - 1)
			)
		OR (
			LENGTH(uppr.concept_code) IN (
				3,
				7
				)
			AND lowr.concept_code = SUBSTR(uppr.concept_code, 1, LENGTH(uppr.concept_code) - 2)
			)
		)
	AND uppr.vocabulary_id = 'ATC'
	AND lowr.vocabulary_id = 'ATC'
	AND v.vocabulary_id = 'ATC';

-- 9. Add new relationships
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT cs.class_code AS concept_code_1,
	c.concept_code AS concept_code_2,
	'ATC' AS vocabulary_id_1,
	c.vocabulary_id AS vocabulary_id_2,
	'ATC - RxNorm' AS relationship_id,
	CURRENT_DATE AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM dev_atc.сlass_to_rx_descendant cs --manual source table
JOIN concept c ON c.concept_id = cs.concept_id
WHERE NOT EXISTS  (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = cs.class_code
			AND crs.vocabulary_id_1 = 'ATC'
			AND crs.concept_code_2 = c.concept_code
			AND crs.vocabulary_id_2 = c.vocabulary_id
			AND crs.relationship_id = 'ATC - RxNorm'
		);

-- 10. Add relationships to ingredients excluding multiple-ingredient combos
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT cs.class_code AS concept_code_1,
	c.concept_code AS concept_code_2,
	'ATC' AS vocabulary_id_1,
	c.vocabulary_id AS vocabulary_id_2,
	'ATC - RxNorm' AS relationship_id,
	CURRENT_DATE AS valid_start_date,
	TO_DATE('20991231', 'YYYYMMDD') AS valid_end_date,
	NULL AS invalid_reason
FROM dev_atc.сlass_to_rx_descendant cs
JOIN devv5.concept_ancestor ca ON ca.descendant_concept_id = cs.concept_id
JOIN concept c ON c.concept_id = ca.ancestor_concept_id
	AND c.concept_class_id = 'Ingredient'
	AND c.vocabulary_id LIKE 'RxNorm%'
WHERE NOT cs.class_name ~ 'combination|agents|drugs|supplements|corticosteroids|compounds|sulfonylureas|preparations|thiazides|antacid|antiinfectives|calcium$|potassium$|sodium$|antiseptics|antibiotics|mydriatics|psycholeptic|other|diuretic|nitrates|analgesics'
	AND c.concept_name NOT IN ('Inert Ingredients') -- a component of contraceptive packs
	AND NOT EXISTS  (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = cs.class_code
			AND crs.vocabulary_id_1 = 'ATC'
			AND crs.concept_code_2 = c.concept_code
			AND crs.vocabulary_id_2 = c.vocabulary_id
			AND crs.relationship_id = 'ATC - RxNorm'
		);

-- 11. Add relationships to ingredients for combo drugs where possible
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT class_code AS concept_code_1,
	concept_code AS concept_code_2,
	'ATC' AS vocabulary_id_1,
	vocabulary_id AS vocabulary_id_2,
	'ATC - RxNorm' AS relationship_id,
	CURRENT_DATE AS valid_start_date,
	TO_DATE('20991231', 'YYYYMMDD') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT am.class_code,
		c.concept_code,
		c.vocabulary_id
	FROM dev_atc.ambiguous_class_ingredient am
	JOIN dev_atc.relationship_to_concept rtc ON rtc.concept_code_1 = am.ing
	JOIN concept c ON rtc.concept_id_2 = c.concept_id
	WHERE am.flag = 'ing'
		AND NOT EXISTS  (
			SELECT 1
			FROM dev_atc.ambiguous_class_ingredient am2
			WHERE am.class_code = am2.class_code
				AND am.ing = am2.ing
				AND rtc.precedence > 1
			)

	UNION

	SELECT a.class_code,
		c.concept_code,
		c.vocabulary_id
	FROM dev_atc.class_1_comb a
	LEFT JOIN dev_atc.reference r ON a.class_code = r.class_code
	JOIN dev_atc.internal_relationship_stage i ON coalesce(concept_code, a.class_code) = i.concept_code_1
	JOIN dev_atc.drug_concept_stage d ON d.concept_code = i.concept_code_2
		AND d.concept_class_id = 'Ingredient'
	JOIN dev_atc.relationship_to_concept rtc ON rtc.concept_code_1 = d.concept_code
	JOIN concept c ON rtc.concept_id_2 = c.concept_id
	WHERE a.class_name ~ 'comb| and '
		AND NOT EXISTS  (
			SELECT 1
			FROM dev_atc.relationship_to_concept rtc2
			WHERE rtc.concept_code_1 = rtc2.concept_code_1
				AND rtc2.precedence > 1
			)
	) atc
WHERE NOT EXISTS  (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = atc.class_code
			AND crs.vocabulary_id_1 = 'ATC'
			AND crs.concept_code_2 = atc.concept_code
			AND crs.vocabulary_id_2 = atc.vocabulary_id
			AND crs.relationship_id = 'ATC - RxNorm'
		);

							   
-- 12. Add ingredients from those ATC drugs that didn't match to RxNorm concepts
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
WITH corpus AS (
  SELECT DISTINCT class_code,
                  class_name,
                  i.concept_code_2,
                  rtc.concept_code_1,
                  c.concept_code,
                  c.vocabulary_id,
                  c.concept_name
  FROM internal_relationship_stage i
         JOIN class_drugs_scraper cds ON substring(concept_code_1, '\w+') = class_code
         LEFT JOIN relationship_to_concept rtc ON rtc.concept_code_1 = i.concept_code_2
         LEFT JOIN drug_concept_stage dcs ON dcs.concept_code = i.concept_code_2 AND dcs.concept_class_id = 'Ingredient'
         JOIN concept c ON c.concept_id = rtc.concept_id_2 AND c.concept_class_id = 'Ingredient'
  WHERE class_code NOT IN (
    SELECT class_code 
    FROM class_to_rx_descendant
    )
  AND NOT EXISTS(
      SELECT 1 
      FROM relationship_to_concept rtc2 
      WHERE rtc2.concept_code_1 = rtc.concept_code_1 
        AND precedence > 1
    ))
SELECT class_code AS concept_code_1,
	     concept_code AS concept_code_2,
	     'ATC' AS vocabulary_id_1,
	     vocabulary_id AS vocabulary_id_2,
	     'ATC - RxNorm' AS relationship_id,
	     CURRENT_DATE AS valid_start_date,
    	 TO_DATE('20991231', 'YYYYMMDD') AS valid_end_date,
	     NULL AS invalid_reason
FROM corpus c
WHERE NOT EXISTS (
      SELECT 1 
      FROM corpus c2 
      WHERE c.class_code = c2.class_code 
        AND c2.concept_code_1 IS NULL
  )
AND NOT EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = c.class_code
			AND crs.vocabulary_id_1 = 'ATC'
			AND crs.concept_code_2 = c.concept_code
			AND crs.vocabulary_id_2 = c.vocabulary_id
			AND crs.relationship_id = 'ATC - RxNorm'
		)
;					   
							   
-- 13. Add manual relationships
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.ProcessManualRelationships();
END $_$;

-- 14. Remove ATC's duplicates (AVOF-322)
-- diphtheria immunoglobulin
DELETE FROM concept_relationship_stage WHERE concept_code_1 = 'J06BB10' AND concept_code_2 = '3510' AND relationship_id = 'ATC - RxNorm';
-- hydroquinine
DELETE FROM concept_relationship_stage WHERE concept_code_1 = 'M09AA01' AND concept_code_2 = '27220' AND relationship_id = 'ATC - RxNorm';

-- 15. Deprecate relationships between multi ingredient drugs and a single ATC 5th, because it should have either an ATC for each ingredient or an ATC that is a combination of them
-- 15.1. Create temporary table drug_strength_ext (same code AS IN concept_ancestor, but we exclude ds for ingredients (because we use count(*)>1 AND ds for ingredients HAVING COUNT(*)=1) AND only for RxNorm)
DROP TABLE IF EXISTS  drug_strength_ext;
CREATE UNLOGGED TABLE drug_strength_ext AS
SELECT *
FROM (
	WITH ingredient_unit AS (
			SELECT DISTINCT
				-- pick the most common unit for an ingredient. If there is a draw, pick always the same by sorting by unit_concept_id
				ingredient_concept_code,
				vocabulary_id,
				FIRST_VALUE(unit_concept_id) OVER (
					PARTITION BY ingredient_concept_code ORDER BY cnt DESC,
						unit_concept_id
					) AS unit_concept_id
			FROM (
				-- sum the counts coming FROM amount AND numerator
				SELECT ingredient_concept_code,
					vocabulary_id,
					unit_concept_id,
					SUM(cnt) AS cnt
				FROM (
					-- count ingredients, their units AND the frequency
					SELECT c2.concept_code AS ingredient_concept_code,
						c2.vocabulary_id,
						ds.amount_unit_concept_id AS unit_concept_id,
						COUNT(*) AS cnt
					FROM drug_strength ds
					JOIN concept c1 ON c1.concept_id = ds.drug_concept_id
						AND c1.vocabulary_id = 'RxNorm'
					JOIN concept c2 ON c2.concept_id = ds.ingredient_concept_id
						AND c2.vocabulary_id = 'RxNorm'
					WHERE ds.amount_value <> 0
					GROUP BY c2.concept_code,
						c2.vocabulary_id,
						ds.amount_unit_concept_id

					UNION

					SELECT c2.concept_code AS ingredient_concept_code,
						c2.vocabulary_id,
						ds.numerator_unit_concept_id AS unit_concept_id,
						COUNT(*) AS cnt
					FROM drug_strength ds
					JOIN concept c1 ON c1.concept_id = ds.drug_concept_id
						AND c1.vocabulary_id = 'RxNorm'
					JOIN concept c2 ON c2.concept_id = ds.ingredient_concept_id
						AND c2.vocabulary_id = 'RxNorm'
					WHERE ds.numerator_value <> 0
					GROUP BY c2.concept_code,
						c2.vocabulary_id,
						ds.numerator_unit_concept_id
					) AS s0
				GROUP BY ingredient_concept_code,
					vocabulary_id,
					unit_concept_id
				) AS s1
			)
	-- Create drug_strength for drug forms
	SELECT de.concept_code AS drug_concept_code,
		an.concept_code AS ingredient_concept_code
	FROM concept an
	JOIN devv5.concept_ancestor ca ON ca.ancestor_concept_id = an.concept_id
	JOIN concept de ON de.concept_id = ca.descendant_concept_id
	JOIN ingredient_unit iu ON iu.ingredient_concept_code = an.concept_code
		AND iu.vocabulary_id = an.vocabulary_id
	WHERE an.vocabulary_id = 'RxNorm'
		AND an.concept_class_id = 'Ingredient'
		AND de.vocabulary_id = 'RxNorm'
		AND de.concept_class_id IN (
			'Clinical Drug Form',
			'Branded Drug Form'
			)
	) AS s2;

-- 15.2. Do deprecation
DELETE
FROM concept_relationship_stage
WHERE ctid IN (
		SELECT drug2atc.row_id
		FROM (
			SELECT drug_concept_code
			FROM (
				SELECT c1.concept_code AS drug_concept_code,
					c2.concept_code
				FROM drug_strength ds
				JOIN concept c1 ON c1.concept_id = ds.drug_concept_id
					AND c1.vocabulary_id = 'RxNorm'
				JOIN concept c2 ON c2.concept_id = ds.ingredient_concept_id

				UNION

				SELECT drug_concept_code,
					ingredient_concept_code
				FROM drug_strength_ext
				) AS s0
			GROUP BY drug_concept_code
			HAVING count(*) > 1
			) all_drugs
		JOIN (
			SELECT *
			FROM (
				SELECT crs.ctid row_id,
					crs.concept_code_2,
					count(*) OVER (PARTITION BY crs.concept_code_2) cnt_atc
				FROM concept_relationship_stage crs
				JOIN concept_stage cs ON cs.concept_code = crs.concept_code_1
					AND cs.vocabulary_id = crs.vocabulary_id_1
					AND cs.vocabulary_id = 'ATC'
					AND cs.concept_class_id = 'ATC 5th'
					AND NOT cs.concept_name ~ 'preparations|virus|antigen|-|/|organisms|insulin|etc\.|influenza|human menopausal gonadotrophin|combination|amino acids|electrolytes| AND |excl\.| with |others|various'
				JOIN concept c ON c.concept_code = crs.concept_code_2
					AND c.vocabulary_id = crs.vocabulary_id_2
					AND c.vocabulary_id = 'RxNorm'
				WHERE crs.relationship_id = 'ATC - RxNorm'
					AND crs.invalid_reason IS NULL
				) AS s1
			WHERE cnt_atc = 1
			) drug2atc ON drug2atc.concept_code_2 = all_drugs.drug_concept_code
		);

-- 16. Add synonyms to concept_synonym stage for each of the rxcui/code combinations IN atc_tmp_table
INSERT INTO concept_synonym_stage (
	synonym_concept_code,
	synonym_name,
	synonym_vocabulary_id,
	language_concept_id
	)
SELECT DISTINCT dv.concept_code AS synonym_concept_code,
	SUBSTR(r.str, 1, 1000) AS synonym_name,
	dv.vocabulary_id AS synonym_vocabulary_id,
	4180186 AS language_concept_id
FROM atc_tmp_table dv
JOIN sources.rxnconso r ON dv.code = r.code
	AND dv.rxcui = r.rxcui
	AND r.code != 'NOCODE'
	AND r.lat = 'ENG';
	    
-- 17. Deprecate RxNorm 'Maps to'
DELETE 
FROM concept_relationship_stage
WHERE relationship_id IN ('Maps to','Mapped from');

-- 18. Working with replacement mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.CheckReplacementMappings();
END $_$;

-- 19. Deprecate 'Maps to' mappings to deprecated and upgraded concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeprecateWrongMAPSTO();
END $_$;

-- 20. Add mapping from deprecated to fresh concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMAPSTO();
END $_$;

-- 21. DELETE ambiguous 'Maps to' mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DELETEAmbiguousMAPSTO();
END $_$;

-- 22. DELETE mappings between concepts that are not represented at the "latest_update" at this moment (e.g. SNOMED <-> RxNorm, but currently we are updating ATC)
--This is because we have SNOMED <-> ATC IN concept_relationship_stage, but AddFreshMAPSTO adds SNOMED <-> RxNorm FROM concept_relationship
DELETE
FROM concept_relationship_stage crs_o
WHERE (
		crs_o.concept_code_1,
		crs_o.vocabulary_id_1,
		crs_o.concept_code_2,
		crs_o.vocabulary_id_2
		) IN (
		SELECT crs.concept_code_1,
			crs.vocabulary_id_1,
			crs.concept_code_2,
			crs.vocabulary_id_2
		FROM concept_relationship_stage crs
		LEFT JOIN vocabulary v1 ON v1.vocabulary_id = crs.vocabulary_id_1
			AND v1.latest_update IS NOT NULL
		LEFT JOIN vocabulary v2 ON v2.vocabulary_id = crs.vocabulary_id_2
			AND v2.latest_update IS NOT NULL
		WHERE coalesce(v1.latest_update, v2.latest_update) IS NULL
		);

-- 23. Clean up
DROP TABLE atc_tmp_table;
DROP TABLE drug_strength_ext;

-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script
