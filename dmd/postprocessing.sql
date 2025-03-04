-- old mappings to RxN* are not deprecated automatically
insert into concept_relationship_stage
select distinct
	null :: int4,
	null :: int4,
	c.concept_code,
	c2.concept_code,
	'dm+d',
	c2.vocabulary_id,
	'Maps to',
	r.valid_start_date,
	current_date - 1,
	'D'
from concept_relationship r
join concept c on 
	c.concept_id = r.concept_id_1 and
	c.vocabulary_id = 'dm+d' and
	r.relationship_id = 'Maps to'
join relationship_to_concept t on
	c.concept_code = t.concept_code_1
join concept cx on
	cx.concept_id = t.concept_id_2 and
	cx.vocabulary_id = 'CVX'
join concept c2 on
	c2.concept_id = r.concept_id_2
where c2.vocabulary_id like 'RxN%'
;--save CVX mappings from relationship_to_concept
insert into concept_relationship_stage
select
	null,
	null,
	r.concept_code_1,
	c.concept_code,
	'dm+d',
	'CVX',
	'Maps to',
	current_date,
	TO_DATE('20991231','yyyymmdd'),
	null
from relationship_to_concept r
join concept c on
	r.concept_id_2 = c.concept_id and
	c.vocabulary_id = 'CVX'
;
--add replacements for VMPs, replaced by source
insert into concept_stage
select
	null :: int4 as concept_id,
	coalesce (v.nmprev, v.nm) as concept_name,
	case --take domain ID from replacement drug
		when d.vpid is null then 'Drug'
		else 'Device'
	end as domain_id,
	'dm+d',
	'VMP',
	null :: varchar as standard_concept,
	v.vpidprev as concept_code,
	to_date ('19700101','yyyymmdd') as valid_start_date,
	coalesce (v.NMDT, current_date - 1) as valid_end_date,
	'U' as invalid_reason
from vmps v
left join vmps u on --make sure old code was not processed on it's own
	v.vpidprev = u.vpid
left join devices d on u.vpid = d.vpid
where 
	v.vpidprev is not null and
	u.vpid is null
;
insert into concept_relationship_stage
select
	null :: int4 as concept_id_1,
	null :: int4 as concept_id_2,
	v.vpidprev as concept_code_1,
	v.vpid as concept_code_2,
	'dm+d',
	'dm+d',
	'Maps to',
	coalesce (v.NMDT, current_date) as valid_start_date,
	to_date ('20991231','yyyymmdd') as valid_end_date,
	null as invalid_reason
from vmps v
left join vmps u on --make sure old code was not processed on it's own
	v.vpidprev = u.vpid
where
	v.vpidprev is not null and
	u.vpid is null
;
--Devices can and should be mapped to SNOMED as they are the same concepts
insert into concept_relationship_stage
select distinct
	null :: int4 as concept_id_1,
	null :: int4 as concept_id_2,
	c.concept_code as concept_code_1,
	x.concept_code as concept_code_2,
	'dm+d',
	'SNOMED',
	'Maps to',
	current_date as valid_start_date,
	to_date ('20991231','yyyymmdd') as valid_end_date,
	null as invalid_reason
from concept_stage c 
join concept x on
	x.concept_code = c.concept_code and

	x.invalid_reason is null and
	x.vocabulary_id = 'SNOMED' and
	x.standard_concept = 'S' and 
	x.domain_id = 'Device' and -- some are Observations, we don't want them

	c.vocabulary_id = 'dm+d' and
	c.domain_id = 'Device'
;
--SNOMED mappings now take precedence
update concept_relationship_stage r
set 
	invalid_reason = 'D',
	valid_end_date = 
	(
        SELECT MAX(latest_update) - 1
        FROM vocabulary
        WHERE vocabulary_id IN (r.vocabulary_id_1, r.vocabulary_id_2)
              AND latest_update IS NOT NULL
      )
where
	vocabulary_id_2 != 'SNOMED' and
	relationship_id = 'Maps to' and
	invalid_reason is null and
	exists
		(
			select 
			from concept_relationship_stage
			where
				concept_code_1 = r.concept_code_1 and
				vocabulary_id_2 = 'SNOMED' and
				relationship_id = 'Maps to'
		)
;
update concept_stage 
set standard_concept = NULL
where
	domain_id = 'Device' and
	vocabulary_id = 'dm+d' and
	exists
		(
			select
			from concept_relationship_stage
			where
				concept_code_1 = concept_code and
				relationship_id = 'Maps to' and
				vocabulary_id_2 = 'SNOMED'
		)
;
analyze concept_relationship_stage
;
delete from concept_relationship_stage i
where
	(concept_code_1, vocabulary_id_1, concept_code_2, vocabulary_id_2/*, relationship_id*/) not in
	(
		select
			c1.concept_code,
			c1.vocabulary_id,
			c2.concept_code,
			c2.vocabulary_id/*,
			r.relationship_id*/
		from concept_relationship r
		join concept c1 on
			c1.concept_id = r.concept_id_1 and
			(c1.concept_code, c1.vocabulary_id) = (i.concept_code_1, i.vocabulary_id_1)
		join concept c2 on
			c2.concept_id = r.concept_id_2 and
			(c2.concept_code, c2.vocabulary_id) = (i.concept_code_2, i.vocabulary_id_2)
	) and
	invalid_reason is not null
;
-- Working with replacement mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.CheckReplacementMappings();
END $_$;

-- Deprecate 'Maps to' mappings to deprecated and upgraded concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeprecateWrongMAPSTO();
END $_$;

-- Add mapping from deprecated to fresh concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMAPSTO();
END $_$;

	-- Delete ambiguous 'Maps to' mappings
	DO $_$
	BEGIN
		PERFORM VOCABULARY_PACK.DeleteAmbiguousMAPSTO();
	END $_$;
;
--select devv5.genericupdate()
--;
