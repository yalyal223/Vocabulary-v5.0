/**************************************************************************
* Copyright 2016 Observational Health Data Sciences and Informatics (OHDSI)
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
* 
* Authors: Timur Vakhitov, Christian Reich
* Date: 2017
**************************************************************************/

-- 1. Update latest_update field to new date 
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.SetLatestUpdate(
	pVocabularyName			=> 'RxNorm',
	pVocabularyDate			=> (SELECT vocabulary_date FROM sources.rxnatomarchive LIMIT 1),
	pVocabularyVersion		=> (SELECT vocabulary_version FROM sources.rxnatomarchive LIMIT 1),
	pVocabularyDevSchema	=> 'DEV_RXNORM'
);
END $_$;

-- 2. Truncate all working tables
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE concept_synonym_stage;
TRUNCATE TABLE pack_content_stage;
TRUNCATE TABLE drug_strength_stage;

--3. Insert into concept_stage
-- Get drugs, components, forms and ingredients
INSERT INTO concept_stage (
	concept_name,
	vocabulary_id,
	domain_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT SUBSTR(str, 1, 255),
	'RxNorm',
	'Drug',
	-- use RxNorm tty as for Concept Classes
	CASE tty
		WHEN 'IN'
			THEN 'Ingredient'
		WHEN 'DF'
			THEN 'Dose Form'
		WHEN 'SCDC'
			THEN 'Clinical Drug Comp'
		WHEN 'SCDF'
			THEN 'Clinical Drug Form'
		WHEN 'SCD'
			THEN 'Clinical Drug'
		WHEN 'BN'
			THEN 'Brand Name'
		WHEN 'SBDC'
			THEN 'Branded Drug Comp'
		WHEN 'SBDF'
			THEN 'Branded Drug Form'
		WHEN 'SBD'
			THEN 'Branded Drug'
		WHEN 'PIN'
			THEN 'Precise Ingredient'
		WHEN 'DFG'
			THEN 'Dose Form Group'
		WHEN 'SCDG'
			THEN 'Clinical Dose Group'
		WHEN 'SBDG'
			THEN 'Branded Dose Group'
		END,
	-- only Ingredients, drug components, drug forms, drugs and packs are standard concepts
	CASE tty
		WHEN 'PIN'
			THEN NULL
		WHEN 'DFG'
			THEN 'C'
		WHEN 'SCDG'
			THEN 'C'
		WHEN 'SBDG'
			THEN 'C'
		WHEN 'DF'
			THEN NULL
		WHEN 'BN'
			THEN NULL
		ELSE 'S'
		END,
	-- the code used in RxNorm
	rxcui,
	(
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		),
	CASE 
		WHEN EXISTS (
				SELECT 1
				FROM sources.rxnatomarchive arch
				WHERE arch.rxcui = rx.rxcui
					AND sab = 'RXNORM'
					AND tty IN (
						'IN',
						'DF',
						'SCDC',
						'SCDF',
						'SCD',
						'BN',
						'SBDC',
						'SBDF',
						'SBD',
						'PIN',
						'DFG',
						'SCDG',
						'SBDG'
						)
					AND rxcui <> merged_to_rxcui
				)
			THEN (
					SELECT latest_update - 1
					FROM vocabulary
					WHERE vocabulary_id = 'RxNorm'
					)
		ELSE TO_DATE('20991231', 'yyyymmdd')
		END AS valid_end_date,
	CASE 
		WHEN EXISTS (
				SELECT 1
				FROM sources.rxnatomarchive arch
				WHERE arch.rxcui = rx.rxcui
					AND sab = 'RXNORM'
					AND tty IN (
						'IN',
						'DF',
						'SCDC',
						'SCDF',
						'SCD',
						'BN',
						'SBDC',
						'SBDF',
						'SBD',
						'PIN',
						'DFG',
						'SCDG',
						'SBDG'
						)
					AND rxcui <> merged_to_rxcui
				)
			THEN 'U'
		ELSE NULL
		END
FROM sources.rxnconso rx
WHERE sab = 'RXNORM'
	AND tty IN (
		'IN',
		'DF',
		'SCDC',
		'SCDF',
		'SCD',
		'BN',
		'SBDC',
		'SBDF',
		'SBD',
		'PIN',
		'DFG',
		'SCDG',
		'SBDG'
		);

-- Packs share rxcuis with Clinical Drugs and Branded Drugs, therefore use code as concept_code
INSERT INTO concept_stage (
	concept_name,
	vocabulary_id,
	domain_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT SUBSTR(str, 1, 255),
	'RxNorm',
	'Drug',
	-- use RxNorm tty as for Concept Classes
	CASE tty
		WHEN 'BPCK'
			THEN 'Branded Pack'
		WHEN 'GPCK'
			THEN 'Clinical Pack'
		END,
	'S',
	-- Cannot use rxcui here
	code,
	(
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		),
	CASE 
		WHEN EXISTS (
				SELECT 1
				FROM sources.rxnatomarchive arch
				WHERE arch.rxcui = rx.rxcui
					AND sab = 'RXNORM'
					AND tty IN (
						'IN',
						'DF',
						'SCDC',
						'SCDF',
						'SCD',
						'BN',
						'SBDC',
						'SBDF',
						'SBD',
						'PIN',
						'DFG',
						'SCDG',
						'SBDG'
						)
					AND rxcui <> merged_to_rxcui
				)
			THEN (
					SELECT latest_update - 1
					FROM vocabulary
					WHERE vocabulary_id = 'RxNorm'
					)
		ELSE TO_DATE('20991231', 'yyyymmdd')
		END AS valid_end_date,
	CASE 
		WHEN EXISTS (
				SELECT 1
				FROM sources.rxnatomarchive arch
				WHERE arch.rxcui = rx.code
					AND sab = 'RXNORM'
					AND tty IN (
						'IN',
						'DF',
						'SCDC',
						'SCDF',
						'SCD',
						'BN',
						'SBDC',
						'SBDF',
						'SBD',
						'PIN',
						'DFG',
						'SCDG',
						'SBDG'
						)
					AND rxcui <> merged_to_rxcui
				)
			THEN 'U'
		ELSE NULL
		END
FROM sources.rxnconso rx
WHERE rx.sab = 'RXNORM'
	AND rx.tty IN (
		'BPCK',
		'GPCK'
		);

--4. Add synonyms - for all classes except the packs (they use code as concept_code)
INSERT INTO concept_synonym_stage (
	synonym_concept_code,
	synonym_name,
	synonym_vocabulary_id,
	language_concept_id
	)
SELECT DISTINCT rxcui,
	SUBSTR(rx.str, 1, 1000),
	'RxNorm',
	4180186 -- English
FROM sources.rxnconso rx
JOIN concept_stage c ON c.concept_code = rx.rxcui
	AND c.concept_class_id NOT IN (
		'Clinical Pack',
		'Branded Pack'
		)
	AND c.vocabulary_id = 'RxNorm'
WHERE rx.sab = 'RXNORM'
	AND rx.tty IN (
		'IN',
		'DF',
		'SCDC',
		'SCDF',
		'SCD',
		'BN',
		'SBDC',
		'SBDF',
		'SBD',
		'PIN',
		'DFG',
		'SCDG',
		'SBDG',
		'SY'
		)
	AND c.vocabulary_id = 'RxNorm';

-- Add synonyms for packs
INSERT INTO concept_synonym_stage (
	synonym_concept_code,
	synonym_name,
	synonym_vocabulary_id,
	language_concept_id
	)
SELECT DISTINCT code,
	SUBSTR(rx.str, 1, 1000),
	'RxNorm',
	4180186 -- English
FROM sources.rxnconso rx
JOIN concept_stage c ON c.concept_code = rx.code
	AND c.concept_class_id IN (
		'Clinical Pack',
		'Branded Pack'
		)
	AND c.vocabulary_id = 'RxNorm'
WHERE rx.sab = 'RXNORM'
	AND rx.tty IN (
		'BPCK',
		'GPCK',
		'SY'
		);

--5. Add inner-RxNorm relationships
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
SELECT rxcui2 AS concept_code_1, -- !! The RxNorm source files have the direction the opposite than OMOP
	rxcui1 AS concept_code_2,
	'RxNorm' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	CASE -- 
		WHEN rela = 'has_precise_ingredient'
			THEN 'Has precise ing'
		WHEN rela = 'has_tradename'
			THEN 'Has tradename'
		WHEN rela = 'has_dose_form'
			THEN 'RxNorm has dose form'
		WHEN rela = 'has_form'
			THEN 'Has form' -- links Ingredients to Precise Ingredients
		WHEN rela = 'has_ingredient'
			THEN 'RxNorm has ing'
		WHEN rela = 'constitutes'
			THEN 'Constitutes'
		WHEN rela = 'contains'
			THEN 'Contains'
		WHEN rela = 'reformulated_to'
			THEN 'Reformulated in'
		WHEN rela = 'inverse_isa'
			THEN 'RxNorm inverse is a'
		WHEN rela = 'has_quantified_form'
			THEN 'Has quantified form' -- links extended release tablets to 12 HR extended release tablets
		WHEN rela = 'quantified_form_of'
			THEN 'Quantified form of'
		WHEN rela = 'consists_of'
			THEN 'Consists of'
		WHEN rela = 'ingredient_of'
			THEN 'RxNorm ing of'
		WHEN rela = 'precise_ingredient_of'
			THEN 'Precise ing of'
		WHEN rela = 'dose_form_of'
			THEN 'RxNorm dose form of'
		WHEN rela = 'isa'
			THEN 'RxNorm is a'
		WHEN rela = 'contained_in'
			THEN 'Contained in'
		WHEN rela = 'form_of'
			THEN 'Form of'
		WHEN rela = 'reformulation_of'
			THEN 'Reformulation of'
		WHEN rela = 'tradename_of'
			THEN 'Tradename of'
		WHEN rela = 'doseformgroup_of'
			THEN 'Dose form group of'
		WHEN rela = 'has_doseformgroup'
			THEN 'Has dose form group'
		ELSE 'non-existing'
		END AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT rxcui1,
		rxcui2,
		rela
	FROM sources.rxnrel
	WHERE sab = 'RXNORM'
		AND rxcui1 IS NOT NULL
		AND rxcui2 IS NOT NULL
		AND EXISTS (
			SELECT 1
			FROM concept
			WHERE vocabulary_id = 'RxNorm'
				AND concept_code = rxcui1
			
			UNION ALL
			
			SELECT 1
			FROM concept_stage
			WHERE vocabulary_id = 'RxNorm'
				AND concept_code = rxcui1
			)
		AND EXISTS (
			SELECT 1
			FROM concept
			WHERE vocabulary_id = 'RxNorm'
				AND concept_code = rxcui2
			
			UNION ALL
			
			SELECT 1
			FROM concept_stage
			WHERE vocabulary_id = 'RxNorm'
				AND concept_code = rxcui2
			)
	) AS s0;

--check for non-existing relationships
ALTER TABLE concept_relationship_stage ADD CONSTRAINT tmp_constraint_relid FOREIGN KEY (relationship_id) REFERENCES relationship (relationship_id);
ALTER TABLE concept_relationship_stage DROP CONSTRAINT tmp_constraint_relid;

--Rename "RxNorm has ing" to "Has brand name" if concept_code_2 has the concept_class_id='Brand Name' and reverse
UPDATE concept_relationship_stage crs_m
SET RELATIONSHIP_ID = 'Has brand name'
WHERE EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		LEFT JOIN concept_stage cs ON cs.concept_code = crs.concept_code_2
			AND cs.vocabulary_id = crs.vocabulary_id_2
			AND cs.concept_class_id = 'Brand Name'
		LEFT JOIN concept c ON c.concept_code = crs.concept_code_2
			AND c.vocabulary_id = crs.vocabulary_id_2
			AND c.concept_class_id = 'Brand Name'
		WHERE crs.invalid_reason IS NULL
			AND crs.relationship_id = 'RxNorm has ing'
			AND COALESCE(cs.concept_code, c.concept_code) IS NOT NULL
			AND crs_m.concept_code_1 = crs.concept_code_1
			AND crs_m.vocabulary_id_1 = crs.vocabulary_id_1
			AND crs_m.concept_code_2 = crs.concept_code_2
			AND crs_m.vocabulary_id_2 = crs.vocabulary_id_2
			AND crs_m.relationship_id = crs.relationship_id
		);

--reverse
UPDATE concept_relationship_stage crs_m
SET RELATIONSHIP_ID = 'Brand name of'
WHERE EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		LEFT JOIN concept_stage cs ON cs.concept_code = crs.concept_code_1
			AND cs.vocabulary_id = crs.vocabulary_id_1
			AND cs.concept_class_id = 'Brand Name'
		LEFT JOIN concept c ON c.concept_code = crs.concept_code_1
			AND c.vocabulary_id = crs.vocabulary_id_1
			AND c.concept_class_id = 'Brand Name'
		WHERE crs.invalid_reason IS NULL
			AND crs.relationship_id = 'RxNorm ing of'
			AND COALESCE(cs.concept_code, c.concept_code) IS NOT NULL
			AND crs_m.concept_code_1 = crs.concept_code_1
			AND crs_m.vocabulary_id_1 = crs.vocabulary_id_1
			AND crs_m.concept_code_2 = crs.concept_code_2
			AND crs_m.vocabulary_id_2 = crs.vocabulary_id_2
			AND crs_m.relationship_id = crs.relationship_id
		);

-- Add missing relationships between Branded Packs and their Brand Names
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
WITH pb AS (
		SELECT *
		FROM (
			SELECT pack_code,
				pack_brand,
				brand_code,
				brand_name
			FROM (
				-- The brand names are either listed as tty PSN (prescribing name) or SY (synonym). If they are not listed they don't exist
				SELECT p.rxcui AS pack_code,
					coalesce(b.str, s.str) AS pack_brand
				FROM sources.rxnconso p
				LEFT JOIN sources.rxnconso b ON p.rxcui = b.rxcui
					AND b.sab = 'RXNORM'
					AND b.tty = 'PSN'
				LEFT JOIN sources.rxnconso s ON p.rxcui = s.rxcui
					AND s.sab = 'RXNORM'
					AND s.tty = 'SY'
				WHERE p.sab = 'RXNORM'
					AND p.tty = 'BPCK'
				) AS s0
			JOIN (
				SELECT concept_code AS brand_code,
					concept_name AS brand_name
				FROM concept_stage
				WHERE vocabulary_id = 'RxNorm'
					AND concept_class_id = 'Brand Name'
				) AS s1 ON REPLACE(pack_brand, '-', ' ') ILIKE '%' || REPLACE(brand_name, '-', ' ') || '%'
			) AS s2
		-- apply the slow regexp only to the ones preselected by instr
		WHERE LOWER(REPLACE(pack_brand, '-', ' ')) ~ ('(^|\s|\W)' || LOWER(REPLACE(brand_name, '-', ' ')) || '($|\s|\W)')
		)
SELECT DISTINCT pack_code AS concept_code_1,
	brand_code AS concept_code_2,
	'RxNorm' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	'Has brand name' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pb p
-- kick out those duplicates where one is part of antoher brand name (like 'Demulen' in 'Demulen 1/50', or those that cannot be part of each other.
WHERE NOT EXISTS (
		SELECT 1
		FROM pb q
		WHERE q.brand_code != p.brand_code
			AND p.pack_code = q.pack_code
			AND (
				devv5.INSTR(q.brand_name, p.brand_name) > 0
				OR devv5.INSTR(q.brand_name, p.brand_name) = 0
				AND devv5.INSTR(p.brand_name, q.brand_name) = 0
				)
		)
	AND NOT EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = pack_code
			AND crs.concept_code_2 = brand_code
			AND crs.relationship_id = 'Has brand name'
		)
	AND NOT EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_2 = pack_code
			AND crs.concept_code_1 = brand_code
			AND crs.relationship_id = 'Brand name of'
		);

-- Remove shortcut 'RxNorm has ing' relationship between 'Clinical Drug', 'Quant Clinical Drug', 'Clinical Pack' and 'Ingredient'
DELETE
FROM concept_relationship_stage r
WHERE EXISTS (
		SELECT 1
		FROM concept_stage d
		WHERE r.concept_code_1 = d.concept_code
			AND r.vocabulary_id_1 = d.vocabulary_id
			AND d.concept_class_id IN (
				'Clinical Drug',
				'Quant Clinical Drug',
				'Clinical Pack'
				)
		)
	AND EXISTS (
		SELECT 1
		FROM concept_stage d
		WHERE r.concept_code_2 = d.concept_code
			AND r.vocabulary_id_2 = d.vocabulary_id
			AND d.concept_class_id = 'Ingredient'
		)
	AND relationship_id = 'RxNorm has ing';

-- and same for reverse
DELETE
FROM concept_relationship_stage r
WHERE EXISTS (
		SELECT 1
		FROM concept_stage d
		WHERE r.concept_code_2 = d.concept_code
			AND r.vocabulary_id_1 = d.vocabulary_id
			AND d.concept_class_id IN (
				'Clinical Drug',
				'Quant Clinical Drug',
				'Clinical Pack'
				)
		)
	AND EXISTS (
		SELECT 1
		FROM concept_stage d
		WHERE r.concept_code_1 = d.concept_code
			AND r.vocabulary_id_2 = d.vocabulary_id
			AND d.concept_class_id = 'Ingredient'
		)
	AND relationship_id = 'RxNorm ing of';

--Rename 'Has tradename' to 'Has brand name'  where concept_id_1='Ingredient' and concept_id_2='Brand Name'
UPDATE concept_relationship_stage crs_m
SET relationship_id = 'Has brand name'
WHERE EXISTS (
		SELECT r.ctid
		FROM concept_relationship_stage r
		WHERE r.relationship_id = 'Has tradename'
			AND EXISTS (
				SELECT 1
				FROM concept_stage cs
				WHERE cs.concept_code = r.concept_code_1
					AND cs.vocabulary_id = r.vocabulary_id_1
					AND cs.concept_class_id = 'Ingredient'
				
				UNION ALL
				
				SELECT 1
				FROM concept c
				WHERE c.concept_code = r.concept_code_1
					AND c.vocabulary_id = r.vocabulary_id_1
					AND c.concept_class_id = 'Ingredient'
				)
			AND EXISTS (
				SELECT 1
				FROM concept_stage cs
				WHERE cs.concept_code = r.concept_code_2
					AND cs.vocabulary_id = r.vocabulary_id_2
					AND cs.concept_class_id = 'Brand Name'
				
				UNION ALL
				
				SELECT 1
				FROM concept c
				WHERE c.concept_code = r.concept_code_2
					AND c.vocabulary_id = r.vocabulary_id_2
					AND c.concept_class_id = 'Brand Name'
				)
			AND crs_m.concept_code_1 = r.concept_code_1
			AND crs_m.vocabulary_id_1 = r.vocabulary_id_1
			AND crs_m.concept_code_2 = r.concept_code_2
			AND crs_m.vocabulary_id_2 = r.vocabulary_id_2
			AND crs_m.relationship_id = r.relationship_id
		);

--and same for reverse
UPDATE concept_relationship_stage crs_m
SET relationship_id = 'Brand name of'
WHERE EXISTS (
		SELECT r.ctid
		FROM concept_relationship_stage r
		WHERE r.relationship_id = 'Tradename of'
			AND EXISTS (
				SELECT 1
				FROM concept_stage cs
				WHERE cs.concept_code = r.concept_code_1
					AND cs.vocabulary_id = r.vocabulary_id_1
					AND cs.concept_class_id = 'Brand Name'
				
				UNION ALL
				
				SELECT 1
				FROM concept c
				WHERE c.concept_code = r.concept_code_1
					AND c.vocabulary_id = r.vocabulary_id_1
					AND c.concept_class_id = 'Brand Name'
				)
			AND EXISTS (
				SELECT 1
				FROM concept_stage cs
				WHERE cs.concept_code = r.concept_code_2
					AND cs.vocabulary_id = r.vocabulary_id_2
					AND cs.concept_class_id = 'Ingredient'
				
				UNION ALL
				
				SELECT 1
				FROM concept c
				WHERE c.concept_code = r.concept_code_2
					AND c.vocabulary_id = r.vocabulary_id_2
					AND c.concept_class_id = 'Ingredient'
				)
			AND crs_m.concept_code_1 = r.concept_code_1
			AND crs_m.vocabulary_id_1 = r.vocabulary_id_1
			AND crs_m.concept_code_2 = r.concept_code_2
			AND crs_m.vocabulary_id_2 = r.vocabulary_id_2
			AND crs_m.relationship_id = r.relationship_id
		);

--6. Add cross-link and mapping table between SNOMED and RxNorm
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
SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'SNOMED' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	'SNOMED - RxNorm eq' AS relationship_id,
	d.valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept d
JOIN sources.rxnconso r ON r.code = d.concept_code
	AND r.sab = 'SNOMEDCT_US'
	AND r.code != 'NOCODE'
JOIN concept e ON r.rxcui = e.concept_code
	AND e.vocabulary_id = 'RxNorm'
	AND e.invalid_reason IS NULL
WHERE d.vocabulary_id = 'SNOMED'
	AND d.invalid_reason IS NULL
-- Mapping table between SNOMED to RxNorm. SNOMED is both an intermediary between RxNorm AND DM+D, AND a source code

UNION ALL

SELECT DISTINCT d.concept_code AS concept_code_1,
	e.concept_code AS concept_code_2,
	'SNOMED' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	d.valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept d
JOIN sources.rxnconso r ON r.code = d.concept_code
	AND r.sab = 'SNOMEDCT_US'
	AND r.code != 'NOCODE'
JOIN concept e ON r.rxcui = e.concept_code
	AND e.vocabulary_id = 'RxNorm'
	AND e.invalid_reason IS NULL
WHERE d.vocabulary_id = 'SNOMED'
	AND d.invalid_reason IS NULL
	AND d.concept_class_id NOT IN (
		'Dose Form',
		'Brand Name'
		);

--7. Add upgrade relationships (concept_code_2 shouldn't exists in rxnsat with atn = 'RXN_QUALITATIVE_DISTINCTION')
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
SELECT DISTINCT raa.rxcui AS concept_code_1,
	raa.merged_to_rxcui AS concept_code_2,
	'RxNorm' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	'Concept replaced by' AS relationship_id,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM sources.rxnatomarchive raa
JOIN vocabulary v ON v.vocabulary_id = 'RxNorm' -- for getting the latest_update
LEFT JOIN sources.rxnsat rxs ON rxs.rxcui = raa.merged_to_rxcui
	AND rxs.atn = 'RXN_QUALITATIVE_DISTINCTION'
	AND rxs.sab = raa.sab
WHERE raa.sab = 'RXNORM'
	AND raa.tty IN (
		'IN',
		'DF',
		'SCDC',
		'SCDF',
		'SCD',
		'BN',
		'SBDC',
		'SBDF',
		'SBD',
		'PIN',
		'DFG',
		'SCDG',
		'SBDG'
		)
	AND raa.rxcui <> raa.merged_to_rxcui
	AND rxs.rxcui IS NULL;

--7.1. Add 'Maps to' between RXN_QUALITATIVE_DISTINCTION and fresh concepts (AVOF-457)
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
SELECT raa.merged_to_rxcui AS concept_code_1,
	crs.concept_code_2 AS concept_code_2,
	'RxNorm' AS vocabulary_id_1,
	'RxNorm' AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept_relationship_stage crs
JOIN sources.rxnatomarchive raa ON raa.sab = 'RXNORM'
	AND raa.tty IN (
		'IN',
		'DF',
		'SCDC',
		'SCDF',
		'SCD',
		'BN',
		'SBDC',
		'SBDF',
		'SBD',
		'PIN',
		'DFG',
		'SCDG',
		'SBDG'
		)
	AND raa.rxcui = crs.concept_code_1
	AND raa.merged_to_rxcui <> crs.concept_code_2
JOIN sources.rxnsat rxs ON rxs.rxcui = raa.merged_to_rxcui
	AND rxs.atn = 'RXN_QUALITATIVE_DISTINCTION'
	AND rxs.sab = raa.sab
JOIN vocabulary v ON v.vocabulary_id = 'RxNorm'
WHERE crs.relationship_id = 'Concept replaced by'
	AND crs.invalid_reason IS NULL
	AND crs.vocabulary_id_1 = 'RxNorm'
	AND crs.vocabulary_id_2 = 'RxNorm';

--7.2. Set standard_concept = NULL for all affected codes with RXN_QUALITATIVE_DISTINCTION (AVOF-457)
UPDATE concept_stage
SET standard_concept = NULL
WHERE (
		concept_code,
		vocabulary_id
		) IN (
		SELECT raa.merged_to_rxcui,
			crs.vocabulary_id_2
		FROM concept_relationship_stage crs
		JOIN sources.rxnatomarchive raa ON raa.sab = 'RXNORM'
			AND raa.tty IN (
				'IN',
				'DF',
				'SCDC',
				'SCDF',
				'SCD',
				'BN',
				'SBDC',
				'SBDF',
				'SBD',
				'PIN',
				'DFG',
				'SCDG',
				'SBDG'
				)
			AND raa.rxcui = crs.concept_code_1
			AND raa.merged_to_rxcui <> crs.concept_code_2
		JOIN sources.rxnsat rxs ON rxs.rxcui = raa.merged_to_rxcui
			AND rxs.atn = 'RXN_QUALITATIVE_DISTINCTION'
			AND rxs.sab = raa.sab
		WHERE crs.relationship_id = 'Concept replaced by'
			AND crs.invalid_reason IS NULL
			AND crs.vocabulary_id_1 = 'RxNorm'
			AND crs.vocabulary_id_2 = 'RxNorm'
		);

--7.3. Revive concepts which have status='active' in https://rxnav.nlm.nih.gov/REST/rxcuihistory/status.xml?type=active, but we have them in the concept with invalid_reason='U' (the source changed his mind)
DROP TABLE IF EXISTS wrong_replacements;
CREATE UNLOGGED TABLE wrong_replacements AS

SELECT c.concept_code AS concept_code_1,
	c2.concept_code AS concept_code_2,
	cr.valid_start_date,
	cr.relationship_id
FROM apigrabber.GetRxNormByStatus('active') api --live grabbing
JOIN concept c ON c.concept_code = api.rxcode
	AND c.invalid_reason = 'U'
	AND c.vocabulary_id = 'RxNorm'
JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id
	AND cr.invalid_reason IS NULL
	AND cr.relationship_id = 'Concept replaced by'
JOIN concept c2 ON c2.concept_id = cr.concept_id_2

UNION ALL

--Same situation, the concepts are deprecated, but in the base tables we have them with 'U' [AVOF-1183]
(
	WITH rx AS (
			SELECT c.concept_code AS concept_code_1,
				c2.concept_code AS concept_code_2,
				cr.valid_start_date,
				cr.relationship_id,
				cr.concept_id_1,
				cr.concept_id_2
			FROM concept c
			JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id
				AND cr.relationship_id = 'Concept replaced by'
				AND cr.invalid_reason IS NULL
			JOIN concept c2 ON c2.concept_id = cr.concept_id_2
			LEFT JOIN concept_stage cs ON cs.concept_code = c.concept_code
			WHERE EXISTS (
					--there must be at least one record with rxcui = merged_to_rxcui...
					SELECT 1
					FROM sources.rxnatomarchive arch
					WHERE arch.rxcui = arch.merged_to_rxcui
						AND arch.rxcui = c.concept_code
						AND arch.sab = 'RXNORM'
						AND arch.tty IN (
							'IN',
							'DF',
							'SCDC',
							'SCDF',
							'SCD',
							'BN',
							'SBDC',
							'SBDF',
							'SBD',
							'PIN',
							'DFG',
							'SCDG',
							'SBDG'
							)
					)
				AND NOT EXISTS (
					--...and there should be no records rxcui <> merged_to_rxcui
					SELECT 1
					FROM sources.rxnatomarchive arch
					WHERE arch.rxcui <> arch.merged_to_rxcui
						AND arch.rxcui = c.concept_code
						AND arch.sab = 'RXNORM'
						AND arch.tty IN (
							'IN',
							'DF',
							'SCDC',
							'SCDF',
							'SCD',
							'BN',
							'SBDC',
							'SBDF',
							'SBD',
							'PIN',
							'DFG',
							'SCDG',
							'SBDG'
							)
					)
				AND c.invalid_reason = 'U'
				AND c.vocabulary_id = 'RxNorm'
				AND c2.vocabulary_id = 'RxNorm'
				AND cs.concept_code IS NULL --missing from concept_stage (rxnconso)
			)
	SELECT rx.concept_code_1,
		rx.concept_code_2,
		rx.valid_start_date,
		rx.relationship_id
	FROM rx
	
	UNION ALL
	--Kill 'Maps to' as well
	SELECT rx.concept_code_1,
		rx.concept_code_2,
		r.valid_start_date,
		r.relationship_id
	FROM rx
	JOIN concept_relationship r ON r.concept_id_1 = rx.concept_id_1
		AND r.concept_id_2 = rx.concept_id_2
		AND r.relationship_id = 'Maps to'
		AND r.invalid_reason IS NULL
	);

--7.3.1 deprecate current replacements
UPDATE concept_relationship_stage crs
SET valid_end_date = (
		SELECT latest_update - 1
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		),
	invalid_reason = 'D'
FROM wrong_replacements wr
WHERE crs.concept_code_1 = wr.concept_code_1
	AND crs.concept_code_2 = wr.concept_code_2
	AND crs.relationship_id = wr.relationship_id;

--7.3.1 insert new D-replacements
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
SELECT wr.concept_code_1,
	wr.concept_code_2,
	'RxNorm',
	'RxNorm',
	wr.relationship_id,
	wr.valid_start_date,
	(
		SELECT latest_update - 1
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		),
	'D'
FROM wrong_replacements wr
WHERE NOT EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs
		WHERE crs.concept_code_1 = wr.concept_code_1
			AND crs.concept_code_2 = wr.concept_code_2
			AND crs.relationship_id = wr.relationship_id
		);

DROP TABLE wrong_replacements;

--7.3.2 special fix for code=1000589 (RxNorm bug, concept is U but should be alive)
--set concept alive
INSERT INTO concept_stage (
	concept_name,
	vocabulary_id,
	domain_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT 'autologous cultured chondrocytes',
	'RxNorm',
	'Drug',
	'Ingredient',
	'S',
	'1000589',
	TO_DATE('20100905', 'yyyymmdd'),
	TO_DATE('20991231', 'yyyymmdd'),
	NULL
WHERE NOT EXISTS (
		SELECT 1
		FROM concept_stage
		WHERE concept_code = '1000589'
		);

--kill replacement relationship
UPDATE concept_relationship_stage crs
SET valid_end_date = (
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = 'RxNorm'
		),
	invalid_reason = 'D'
WHERE crs.concept_code_1 = '1000589'
	AND crs.concept_code_2 = '350141'
	AND crs.relationship_id = 'Concept replaced by';

--7.4 Delete non-existing concepts from concept_relationship_stage
DELETE
FROM concept_relationship_stage crs
WHERE (
		crs.concept_code_1,
		crs.vocabulary_id_1,
		crs.concept_code_2,
		crs.vocabulary_id_2
		) IN (
		SELECT crm.concept_code_1,
			crm.vocabulary_id_1,
			crm.concept_code_2,
			crm.vocabulary_id_2
		FROM concept_relationship_stage crm
		LEFT JOIN concept c1 ON c1.concept_code = crm.concept_code_1
			AND c1.vocabulary_id = crm.vocabulary_id_1
		LEFT JOIN concept_stage cs1 ON cs1.concept_code = crm.concept_code_1
			AND cs1.vocabulary_id = crm.vocabulary_id_1
		LEFT JOIN concept c2 ON c2.concept_code = crm.concept_code_2
			AND c2.vocabulary_id = crm.vocabulary_id_2
		LEFT JOIN concept_stage cs2 ON cs2.concept_code = crm.concept_code_2
			AND cs2.vocabulary_id = crm.vocabulary_id_2
		WHERE (
				c1.concept_code IS NULL
				AND cs1.concept_code IS NULL
				)
			OR (
				c2.concept_code IS NULL
				AND cs2.concept_code IS NULL
				)
		);

--7.5 Add 'Maps to' as part (duplicate) of the 'Form of' relationship between 'Precise Ingredient' and 'Ingredient' (AVOF-1167)
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
SELECT crs.concept_code_1,
	crs.concept_code_2,
	crs.vocabulary_id_1,
	crs.vocabulary_id_2,
	'Maps to',
	crs.valid_start_date,
	crs.valid_end_date,
	NULL
FROM concept_relationship_stage crs
JOIN concept_stage c1 ON c1.concept_code = crs.concept_code_1
	AND c1.vocabulary_id = crs.vocabulary_id_1
	AND c1.concept_class_id = 'Precise Ingredient'
	AND c1.vocabulary_id = 'RxNorm'
JOIN concept_stage c2 ON c2.concept_code = crs.concept_code_2
	AND c2.vocabulary_id = crs.vocabulary_id_2
	AND c2.concept_class_id = 'Ingredient'
	AND c2.vocabulary_id = 'RxNorm'
	AND c2.standard_concept = 'S'
WHERE crs.relationship_id = 'Form of'
	AND crs.invalid_reason IS NULL
	AND NOT EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs_int
		WHERE crs_int.concept_code_1 = crs.concept_code_1
			AND crs_int.concept_code_2 = crs.concept_code_2
			AND crs_int.vocabulary_id_1 = crs.vocabulary_id_1
			AND crs_int.vocabulary_id_2 = crs.vocabulary_id_2
			AND crs_int.relationship_id = 'Maps to'
		);

--7.6 Add manual relationships
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.ProcessManualRelationships();
END $_$;

--8. Working with replacement mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.CheckReplacementMappings();
END $_$;

--9. Deprecate 'Maps to' mappings to deprecated and upgraded concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeprecateWrongMAPSTO();
END $_$;

--10. Add mapping from deprecated to fresh concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMAPSTO();
END $_$;

--11. Delete ambiguous 'Maps to' mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeleteAmbiguousMAPSTO();
END $_$;

--12. Create mapping to self for fresh concepts
ANALYZE concept_relationship_stage;
ANALYZE concept_stage;
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
SELECT concept_code AS concept_code_1,
	concept_code AS concept_code_2,
	c.vocabulary_id AS vocabulary_id_1,
	c.vocabulary_id AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	v.latest_update AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM concept_stage c,
	vocabulary v
WHERE c.vocabulary_id = v.vocabulary_id
	AND c.standard_concept = 'S'
	AND NOT EXISTS -- only new mapping we don't already have
	(
		SELECT 1
		FROM concept_relationship_stage i
		WHERE c.concept_code = i.concept_code_1
			AND c.concept_code = i.concept_code_2
			AND c.vocabulary_id = i.vocabulary_id_1
			AND c.vocabulary_id = i.vocabulary_id_2
			AND i.relationship_id = 'Maps to'
		);
ANALYZE concept_relationship_stage;

--13. Turn "Clinical Drug" to "Quant Clinical Drug" and "Branded Drug" to "Quant Branded Drug"
UPDATE concept_stage c
SET concept_class_id = CASE 
		WHEN concept_class_id = 'Branded Drug'
			THEN 'Quant Branded Drug'
		ELSE 'Quant Clinical Drug'
		END
WHERE concept_class_id IN (
		'Branded Drug',
		'Clinical Drug'
		)
	AND EXISTS (
		SELECT 1
		FROM concept_relationship_stage r
		WHERE r.relationship_id = 'Quantified form of'
			AND r.concept_code_1 = c.concept_code
			AND r.vocabulary_id_1 = c.vocabulary_id
		);

--14. Create pack_content_stage table
INSERT INTO pack_content_stage
SELECT pc.pack_code AS pack_concept_code,
	'RxNorm' AS pack_vocabulary_id,
	cont.concept_code AS drug_concept_code,
	'RxNorm' AS drug_vocabulary_id,
	pc.amount::FLOAT, -- of drug units in the pack
	NULL AS box_size -- number of the overall combinations units
FROM (
	SELECT pack_code,
		-- Parse the number at the beginning of each drug string as the amount
		SUBSTRING(pack_name, '^[0-9]+') AS amount,
		-- Parse the number in parentheses on the second position of the drug string as the quantity factor of a quantified drug (usually not listed in the concept table), not used right now
		TRANSLATE(SUBSTRING(pack_name, '\([0-9]+ [A-Za-z]+\)'), 'a()', 'a') AS quant,
		-- Don't parse the drug name, because it will be found through instr() with the known name of the component (see below)
		pack_name AS drug
	FROM (
		SELECT DISTINCT pack_code,
			-- This is the sequence to split the concept_name of the packs by the semicolon, which replaces the parentheses plus slash (see below)
			TRIM(UNNEST(regexp_matches(pack_name, '[^;]+', 'g'))) AS pack_name
		FROM (
			-- This takes a Pack name, replaces the sequence ') / ' with a semicolon for splitting, and removes the word Pack and everything thereafter (the brand name usually)
			SELECT rxcui AS pack_code,
				REGEXP_REPLACE(REPLACE(REPLACE(str, ') / ', ';'), '{', ''), '\) } Pack( \[.+\])?', '','g') AS pack_name
			FROM sources.rxnconso
			WHERE sab = 'RXNORM'
				AND tty LIKE '%PCK' -- Clinical (=Generic) or Branded Pack
			) AS s0
		) AS s1
	) AS pc
-- match by name with the component drug obtained through the 'Contains' relationship
LEFT JOIN (
	SELECT concept_code_1,
		concept_code_2,
		concept_code,
		concept_name
	FROM concept_relationship_stage r
	JOIN concept_stage ON concept_code = r.concept_code_2
	WHERE r.relationship_id = 'Contains'
		AND r.invalid_reason IS NULL
	) cont ON cont.concept_code_1 = pc.pack_code
	AND pc.drug LIKE '%' || cont.concept_name || '%' -- this is where the component name is fit into the parsed drug name from the Pack string
GROUP BY pc.pack_code,
	cont.concept_code,
	pc.amount;

--15. Run FillDrugStrengthStage
DO $_$
BEGIN
	PERFORM dev_rxnorm.FillDrugStrengthStage();
END $_$;

--16. We need to run generic_update before small RxE clean up
DO $_$
BEGIN
	PERFORM devv5.GenericUpdate();
END $_$;

--17. Run RxE clean up
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.RxECleanUP();
END $_$;

/*
NDFRT, VA Product, VA Class are now retired
see more at https://www.nlm.nih.gov/pubs/techbull/ja18/brief/ja18_ndfrt_removed_rxnorm.html
*/

-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script