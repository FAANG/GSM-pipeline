#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/methylseq
========================================================================================
 nf-core/methylseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/methylseq
----------------------------------------------------------------------------------------
*/

log.info Headers.nf_core(workflow, params.monochrome_logs)

////////////////////////////////////////////////////
/* --               PRINT HELP                 -- */
////////////////////////////////////////////////////+
def json_schema = "$projectDir/nextflow_schema.json"
if (params.help) {
    def command = "nextflow run nf-core/methylseq --input '*_R{1,2}.fastq.gz' -profile docker"
    log.info NfcoreSchema.params_help(workflow, params, json_schema, command)
    exit 0
}

////////////////////////////////////////////////////
/* --         VALIDATE PARAMETERS              -- */
////////////////////////////////////////////////////+

if (params.validate_params) {
    NfcoreSchema.validateParameters(params, json_schema, log)
}

////////////////////////////////////////////////////
/* --     Collect configuration parameters     -- */
////////////////////////////////////////////////////

// These params need to be set late, after the iGenomes config is loaded
params.bismark_index = params.genome ? params.genomes[ params.genome ].bismark ?: false : false
params.bwa_meth_index = params.genome ? params.genomes[ params.genome ].bwa_meth ?: false : false
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.fasta_index = params.genome ? params.genomes[ params.genome ].fasta_index ?: false : false

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(', ')}"
}

Channel
    .fromPath("$projectDir/assets/where_are_my_files.txt", checkIfExists: true)
    .into { ch_wherearemyfiles_for_trimgalore; ch_wherearemyfiles_for_alignment }

ch_splicesites_for_bismark_hisat_align = params.known_splices ? Channel.fromPath(params.known_splices, checkIfExists: true) : Channel.empty()


if( params.aligner =~ /bismark/ ){
    assert params.bismark_index || params.fasta : "No reference genome index or fasta file specified"
    ch_wherearemyfiles_for_alignment.set { ch_wherearemyfiles_for_bismark_align }

    if( params.bismark_index ){
        Channel
            .fromPath(params.bismark_index, checkIfExists: true)
            .ifEmpty { exit 1, "Bismark index file not found: ${params.bismark_index}" }
            .into { ch_bismark_index_for_bismark_align; ch_bismark_index_for_bismark_methXtract }
    }
    else if( params.fasta ){
        Channel
            .fromPath(params.fasta, checkIfExists: true)
            .ifEmpty { exit 1, "fasta file not found : ${params.fasta}" }
            .set { ch_fasta_for_makeBismarkIndex }
    }
}
else if( params.aligner == 'bwameth' ){
    assert params.fasta : "No Fasta reference specified! This is required by MethylDackel."
    ch_wherearemyfiles_for_alignment.into { ch_wherearemyfiles_for_bwamem_align; ch_wherearemyfiles_for_samtools_sort_index_flagstat }

    Channel
        .fromPath(params.fasta, checkIfExists: true)
        .ifEmpty { exit 1, "fasta file not found : ${params.fasta}" }
        .into { ch_fasta_for_makeBwaMemIndex; ch_fasta_for_makeFastaIndex; ch_fasta_for_methyldackel }

    if( params.bwa_meth_index ){
        Channel
            .fromPath("${params.bwa_meth_index}*", checkIfExists: true)
            .ifEmpty { exit 1, "bwa-meth index file(s) not found: ${params.bwa_meth_index}" }
            .set { ch_bwa_meth_indices_for_bwamem_align }
        ch_fasta_for_makeBwaMemIndex.close()
    }

    if( params.fasta_index ){
        Channel
            .fromPath(params.fasta_index, checkIfExists: true)
            .ifEmpty { exit 1, "fasta index file not found: ${params.fasta_index}" }
            .set { ch_fasta_index_for_methyldackel }
        ch_fasta_for_makeFastaIndex.close()
    }
}

Channel
        .fromPath(params.fasta, checkIfExists: true)
        .ifEmpty { exit 1, "fasta file not found : ${params.fasta}" }
        .into { ch_fasta_for_cgmaptools; ch_fasta_bismarkIndex_2 }



// Trimming / kit presets
clip_r1 = params.clip_r1
clip_r2 = params.clip_r2
three_prime_clip_r1 = params.three_prime_clip_r1
three_prime_clip_r2 = params.three_prime_clip_r2
bismark_minins = params.minins
bismark_maxins = params.maxins
if(params.pbat){
    clip_r1 = 9
    clip_r2 = 9
    three_prime_clip_r1 = 9
    three_prime_clip_r2 = 9
}
else if( params.single_cell ){
    clip_r1 = 6
    clip_r2 = 6
    three_prime_clip_r1 = 6
    three_prime_clip_r2 = 6
}
else if( params.epignome ){
    clip_r1 = 8
    clip_r2 = 8
    three_prime_clip_r1 = 8
    three_prime_clip_r2 = 8
}
else if( params.accel || params.zymo ){
    clip_r1 = 10
    clip_r2 = 15
    three_prime_clip_r1 = 10
    three_prime_clip_r2 = 10
}
else if( params.cegx ){
    clip_r1 = 6
    clip_r2 = 6
    three_prime_clip_r1 = 2
    three_prime_clip_r2 = 2
}
else if( params.em_seq ){
    bismark_maxins = 1000
    clip_r1 = 8
    clip_r2 = 8
    three_prime_clip_r1 = 8
    three_prime_clip_r2 = 8
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, 'Specify correct --awsqueue and --awsregion parameters on AWSBatch!'
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, 'Outdir not on S3 - specify S3 Bucket to run on AWSBatch!'
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, 'Specify a local tracedir or run without trace! S3 cannot be used for tracefiles.'
}

// Stage config files
ch_multiqc_config = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if (params.input_paths) {
    if (params.single_end) {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, 'params.input_paths was empty - no input files supplied' }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    } else {
        Channel
            .from(params.input_paths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, 'params.input_paths was empty - no input files supplied' }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    }
} 

else if (params.aligner == 'none'){
    Channel
        .fromPath(params.bam)
        .map { file -> tuple(file.baseName, file) }
        .ifEmpty { exit 1, 'params.bam_paths was empty - no input files supplied' }
        .set { ch_indep_bam_for_processing }
}
else {
    Channel
        .fromFilePairs(params.input, size: params.single_end ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.input}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
        .into { ch_read_files_fastqc; ch_read_files_trimming}
}
/*        .map { path ->  filename = path.getName()
            if (filename.endsWith('.bam'))
                filename = filename.substring(0, filename.length() - 3)
            return [path, filename] } */

            /* else if (params.aligner == 'none'){
Channel
.fromPath(params.bam)
.map { file -> tuple(file.baseName, file) }
.ifEmpty { exit 1, 'params.bam_paths was empty - no input files supplied' }
.set { ch_indep_bam_for_processing }
}

////////////////////////////////////////////////////
/* --         PRINT PARAMETER SUMMARY          -- */
////////////////////////////////////////////////////
log.info NfcoreSchema.params_summary_log(workflow, params, json_schema)

// Header log info
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']  = workflow.runName
summary['Aligner']   = params.aligner
summary['Data Type'] = params.single_end ? 'Single-End' : 'Paired-End'
if (params.input)           summary['Input']     = params.input
if(params.known_splices)    summary['Spliced alignment'] =  'Yes'
if(params.slamseq)          summary['SLAM-seq'] = 'Yes'
if(params.local_alignment)  summary['Local alignment'] = 'Yes'
if(params.genome)           summary['Genome']    = params.genome
if(params.bismark_index)    summary['Bismark Index'] = params.bismark_index
if(params.bwa_meth_index)   summary['BWA-Meth Index'] = "${params.bwa_meth_index}*"
if(params.fasta)            summary['Fasta Ref'] = params.fasta
if(params.bam)              summary['Bam input'] = params.bam
if(params.fasta_index)      summary['Fasta Index'] = params.fasta_index
if(params.rrbs)             summary['RRBS Mode'] = 'On'
if(params.relax_mismatches) summary['Mismatch Func'] = "L,0,-${params.num_mismatches} (Bismark default = L,0,-0.2)"
if(params.skip_trimming)    summary['Trimming Step'] = 'Skipped'
if(params.skip_alignment)   summary['Trimming Step','FastQC step', 'Build index step', 'Alignment step'] = 'Skipped'
if(params.pbat)             summary['Trim Profile'] = 'PBAT'
if(params.single_cell)      summary['Trim Profile'] = 'Single Cell'
if(params.epignome)         summary['Trim Profile'] = 'TruSeq (EpiGnome)'
if(params.accel)            summary['Trim Profile'] = 'Accel-NGS (Swift)'
if(params.zymo)             summary['Trim Profile'] = 'Zymo Pico-Methyl'
if(params.cegx)             summary['Trim Profile'] = 'CEGX'
if(params.em_seq)           summary['Trim Profile'] = 'EM Seq'
summary['Trimming']         = "5'R1: $clip_r1 / 5'R2: $clip_r2 / 3'R1: $three_prime_clip_r1 / 3'R2: $three_prime_clip_r2"
summary['Deduplication']    = params.skip_deduplication || params.rrbs ? 'No' : 'Yes'
summary['Directional Mode'] = params.single_cell || params.zymo || params.non_directional ? 'No' : 'Yes'
summary['All C Contexts']   = params.comprehensive ? 'Yes' : 'No'
summary['Cytosine report']  = params.cytosine_report ? 'Yes' : 'No'
if(params.min_depth)        summary['Minimum Depth'] = params.min_depth
if(params.ignore_flags)     summary['MethylDackel'] = 'Ignoring SAM Flags'
if(params.methyl_kit)       summary['MethylDackel'] = 'Producing methyl_kit output'
save_intermeds = [];
if(params.save_reference)   save_intermeds.add('Reference genome build')
if(params.save_trimmed)     save_intermeds.add('Trimmed FastQ files')
if(params.unmapped)         save_intermeds.add('Unmapped reads')
if(params.save_align_intermeds) save_intermeds.add('Intermediate BAM files')
if(save_intermeds.size() > 0) summary['Save Intermediates'] = save_intermeds.join(', ')
if(params.minins)           summary['Bismark min insert size'] = bismark_minins
if(params.maxins || params.em_seq) summary['Bismark max insert size'] = bismark_maxins
if(params.bismark_align_cpu_per_multicore) summary['Bismark align CPUs per --multicore'] = params.bismark_align_cpu_per_multicore
if(params.bismark_align_mem_per_multicore) summary['Bismark align memory per --multicore'] = params.bismark_align_mem_per_multicore
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Pipeline dir']     = workflow.projectDir
summary['User']             = workflow.userName
summary['Config Profile']   = workflow.profile
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}

// Check that --project is set for the UPPMAX cluster
if( workflow.profile.contains('uppmax') ){
    if( !params.project ) exit 1, "No UPPMAX project ID found! Use --project"
    summary['Cluster Project'] = params.project
}

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-methylseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/methylseq Workflow Summary'
    section_href: 'https://github.com/nf-core/methylseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf('.csv') > 0) filename
                      else null
        }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml_for_multiqc
    file "software_versions.csv"

    script:
    """
    echo "$workflow.manifest.version" &> v_pipeline.txt
    echo "$workflow.nextflow.version" &> v_nextflow.txt
    bismark_genome_preparation --version &> v_bismark_genome_preparation.txt
    fastqc --version &> v_fastqc.txt
    cutadapt --version &> v_cutadapt.txt
    trim_galore --version &> v_trim_galore.txt
    bismark --version &> v_bismark.txt
    deduplicate_bismark --version &> v_deduplicate_bismark.txt
    bismark_methylation_extractor --version &> v_bismark_methylation_extractor.txt
    bismark2report --version &> v_bismark2report.txt
    bismark2summary --version &> v_bismark2summary.txt
    samtools --version &> v_samtools.txt
    hisat2 --version &> v_hisat2.txt
    bwa &> v_bwa.txt 2>&1 || true
    bwameth.py --version &> v_bwameth.txt
    picard MarkDuplicates --version &> v_picard_markdups.txt 2>&1 || true
    MethylDackel --version &> v_methyldackel.txt
    qualimap --version &> v_qualimap.txt || true
    preseq &> v_preseq.txt
    multiqc --version &> v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * PREPROCESSING - Build Bismark index
 */
if( !params.bismark_index && params.aligner =~ /bismark/ ){
    process makeBismarkIndex {
        publishDir path: { params.save_reference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta_for_makeBismarkIndex

        output:
        file "BismarkIndex" into ch_bismark_index_for_bismark_align, ch_bismark_index_for_bismark_methXtract , ch_bismark_index_for_bismark_methXtract_2

        script:
        aligner = params.aligner == 'bismark_hisat' ? '--hisat2' : '--bowtie2'
        slam = params.slamseq ? '--slam' : ''
        """
        mkdir BismarkIndex
        cp $fasta BismarkIndex/
        bismark_genome_preparation $aligner $slam BismarkIndex
        """
    }
}

/*
 * PREPROCESSING - Build bwa-mem index
 */
if( !params.bwa_meth_index && params.aligner == 'bwameth' ){
    process makeBwaMemIndex {
        tag "$fasta"
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta_for_makeBwaMemIndex

        output:
        file "${fasta}*" into ch_bwa_meth_indices_for_bwamem_align
        file fasta

        script:
        """
        bwameth.py index $fasta
        """
    }
}

/*
 * PREPROCESSING - Index Fasta file
 */
if( !params.fasta_index && params.aligner == 'bwameth' ){
    process makeFastaIndex {
        tag "$fasta"
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta_for_makeFastaIndex

        output:
        file "${fasta}.fai" into ch_fasta_index_for_methyldackel

        script:
        """
        samtools faidx $fasta
        """
    }
}


/*
 * STEP 1 - FastQC
 */
if( params.skip_alignment ){
    ch_fastqc_results_for_multiqc = Channel.from(false)
} else { 
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      filename.indexOf('.zip') > 0 ? "zips/$filename" : "$filename"
        }

    input:
    set val(name), file(reads) from ch_read_files_fastqc

    output:
    file '*_fastqc.{zip,html}' into ch_fastqc_results_for_multiqc

    script:
    """
    fastqc --quiet --threads $task.cpus $reads
    """
}
}

/*
 * STEP 2 - Trim Galore!
 */
if( params.skip_trimming){
    ch_trimmed_reads_for_alignment = ch_read_files_trimming
    ch_trim_galore_results_for_multiqc = Channel.from(false)
} 
else if (params.skip_alignment) {
    ch_read_files_trimming = Channel.from(false)
    ch_trim_galore_results_for_multiqc = Channel.from(false)
}
else {
    process trim_galore {
        tag "$name"
        publishDir "${params.outdir}/trim_galore", mode: params.publish_dir_mode,
            saveAs: {filename ->
                if( filename.indexOf("_fastqc") > 0 ) "FastQC/$filename"
                else if( filename.indexOf("trimming_report.txt" ) > 0) "logs/$filename"
                else if( !params.save_trimmed && filename == "where_are_my_files.txt" ) filename
                else if( params.save_trimmed && filename != "where_are_my_files.txt" ) filename
                else null
            }

        input:
        set val(name), file(reads) from ch_read_files_trimming
        file wherearemyfiles from ch_wherearemyfiles_for_trimgalore.collect()

        output:
        set val(name), file('*fq.gz') into ch_trimmed_reads_for_alignment
        file "*trimming_report.txt" into ch_trim_galore_results_for_multiqc
        file "*_fastqc.{zip,html}"
        file "where_are_my_files.txt"

        script:
        def c_r1 = clip_r1 > 0 ? "--clip_r1 $clip_r1" : ''
        def c_r2 = clip_r2 > 0 ? "--clip_r2 $clip_r2" : ''
        def tpc_r1 = three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 $three_prime_clip_r1" : ''
        def tpc_r2 = three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 $three_prime_clip_r2" : ''
        def rrbs = params.rrbs ? "--rrbs" : ''
        def cores = 1
        if(task.cpus){
            cores = (task.cpus as int) - 4
            if (params.single_end) cores = (task.cpus as int) - 3
            if (cores < 1) cores = 1
            if (cores > 4) cores = 4
        }
        if( params.single_end ) {
            """
            trim_galore --fastqc --gzip $reads \
              $rrbs $c_r1 $tpc_r1 --cores $cores
            """
        } else {
            """
            trim_galore --fastqc --gzip --paired $reads \
              $rrbs $c_r1 $c_r2 $tpc_r1 $tpc_r2 --cores $cores
            """
        }
    }
}

/*
 * STEP 3.1 - align with Bismark
 */
if( params.aligner =~ /bismark/ ){
    process bismark_align {
        tag "$name"
        publishDir "${params.outdir}/bismark_alignments", mode: params.publish_dir_mode,
            saveAs: {filename ->
                if( filename.indexOf(".fq.gz") > 0 ) "unmapped/$filename"
                else if( filename.indexOf("report.txt") > 0 ) "logs/$filename"
                else if( (!params.save_align_intermeds && !params.skip_deduplication && !params.rrbs).every() && filename == "where_are_my_files.txt" ) filename
                else if( (params.save_align_intermeds || params.skip_deduplication || params.rrbs).any() && filename != "where_are_my_files.txt" ) filename
                else null
            }

        input:
        set val(name), file(reads) from ch_trimmed_reads_for_alignment
        file index from ch_bismark_index_for_bismark_align.collect()
        file wherearemyfiles from ch_wherearemyfiles_for_bismark_align.collect()
        file knownsplices from ch_splicesites_for_bismark_hisat_align.collect().ifEmpty([])

        output:
        set val(name), file("*.bam") into ch_bam_for_bismark_deduplicate, ch_bam_for_bismark_summary, ch_bam_for_preseq
        set val(name), file("*report.txt") into ch_bismark_align_log_for_bismark_report, ch_bismark_align_log_for_bismark_summary, ch_bismark_align_log_for_multiqc
        file "*.fq.gz" optional true
        file "where_are_my_files.txt"

        script:
        // Paired-end or single end input files
        input = params.single_end ? reads : "-1 ${reads[0]} -2 ${reads[1]}"

        // Choice of read aligner
        aligner = params.aligner == "bismark_hisat" ? "--hisat2" : "--bowtie2"

        // Optional extra bismark parameters
        splicesites = params.aligner == "bismark_hisat" && params.known_splices ? "--known-splicesite-infile <(hisat2_extract_splice_sites.py ${knownsplices})" : ''
        pbat = params.pbat ? "--pbat" : ''
        non_directional = params.single_cell || params.zymo || params.non_directional ? "--non_directional" : ''
        unmapped = params.unmapped ? "--unmapped" : ''
        mismatches = params.relax_mismatches ? "--score_min L,0,-${params.num_mismatches}" : ''
        soft_clipping = params.local_alignment ? "--local" : ''
        minins = bismark_minins ? "--minins $bismark_minins" : ''
        maxins = bismark_maxins ? "--maxins $bismark_maxins" : ''

        // Try to assign sensible bismark memory units according to what the task was given
        multicore = ''
        if( task.cpus ){
            // Numbers based on recommendation by Felix for a typical mouse genome
            if( params.single_cell || params.zymo || params.non_directional ){
                cpu_per_multicore = 5
                mem_per_multicore = (18.GB).toBytes()
            } else {
                cpu_per_multicore = 3
                mem_per_multicore = (13.GB).toBytes()
            }
            // Check if the user has specified this and overwrite if so
            if(params.bismark_align_cpu_per_multicore) {
                cpu_per_multicore = (params.bismark_align_cpu_per_multicore as int)
            }
            if(params.bismark_align_mem_per_multicore) {
                mem_per_multicore = (params.bismark_align_mem_per_multicore as nextflow.util.MemoryUnit).toBytes()
            }
            // How many multicore splits can we afford with the cpus we have?
            ccore = ((task.cpus as int) / cpu_per_multicore) as int
            // Check that we have enough memory, assuming 13GB memory per instance (typical for mouse alignment)
            try {
                tmem = (task.memory as nextflow.util.MemoryUnit).toBytes()
                mcore = (tmem / mem_per_multicore) as int
                ccore = Math.min(ccore, mcore)
            } catch (all) {
                log.debug "Warning: Not able to define bismark align multicore based on available memory"
            }
            if( ccore > 1 ){
              multicore = "--multicore $ccore"
            }
        }

        // Main command
        """
        bismark $input \\
            $aligner \\
            --bam $pbat $non_directional $unmapped $mismatches $multicore $minins $maxins \\
            --genome $index \\
            $reads \\
            $soft_clipping \\
            $splicesites
        """
    }

    /*
     * STEP 4 - Bismark deduplicate
     */
    if( params.skip_deduplication || params.rrbs ) {
        ch_bam_for_bismark_deduplicate.into { ch_bam_dedup_for_bismark_methXtract; ch_bam_dedup_for_qualimap; ch_bam_cgmaptools }
        ch_bismark_dedup_log_for_bismark_report = Channel.from(false)
        ch_bismark_dedup_log_for_bismark_summary = Channel.from(false)
        ch_bismark_dedup_log_for_multiqc  = Channel.from(false)
    } 

    else{
        process bismark_deduplicate {
            tag "$name"
            publishDir "${params.outdir}/bismark_deduplicated", mode: params.publish_dir_mode,
                saveAs: {filename -> filename.indexOf(".bam") == -1 ? "logs/$filename" : "$filename"}
                
            input:
            set val(name), file(bam) from ch_bam_for_bismark_deduplicate 

            output:
            set val(name), file("*.deduplicated.bam") into ch_bam_dedup_for_bismark_methXtract, ch_bam_dedup_for_qualimap, ch_bam_cgmaptools
            set val(name), file("*.deduplication_report.txt") into ch_bismark_dedup_log_for_bismark_report, ch_bismark_dedup_log_for_bismark_summary, ch_bismark_dedup_log_for_multiqc
                
            script:
            fq_type = params.single_end ? '-s' : '-p'
            """
            deduplicate_bismark $fq_type --bam $bam
            """
            }
    }

    /*
     * STEP 5 - Bismark methylation extraction
     */
    process bismark_methXtract {
        tag "$name"
        publishDir "${params.outdir}/bismark_methylation_calls", mode: params.publish_dir_mode,
            saveAs: {filename ->
                if( filename.indexOf("splitting_report.txt" ) > 0 ) "logs/$filename"
                else if( filename.indexOf("M-bias" ) > 0) "m-bias/$filename"
                else if( filename.indexOf(".cov" ) > 0 ) "methylation_coverage/$filename"
                else if( filename.indexOf("bedGraph" ) > 0 ) "bedGraph/$filename"
                else if( filename.indexOf("CpG_report" ) > 0 ) "stranded_CpG_report/$filename"
                else "methylation_calls/$filename"
            }

        input:
        set val(name), file(bam) from ch_bam_dedup_for_bismark_methXtract
        file index from ch_bismark_index_for_bismark_methXtract.collect()

        output:
        set val(name), file("*splitting_report.txt") into ch_bismark_splitting_report_for_bismark_report, ch_bismark_splitting_report_for_bismark_summary, ch_bismark_splitting_report_for_multiqc
        set val(name), file("*.M-bias.txt") into ch_bismark_mbias_for_bismark_report, ch_bismark_mbias_for_bismark_summary, ch_bismark_mbias_for_multiqc
        file '*.{png,gz}'
        set val(name), file("*.CX_report.txt") into ch_bismark_to_cgmap_OG

        script:
        comprehensive = params.comprehensive ? '--comprehensive --merge_non_CpG' : ''
        cytosine_report = params.cytosine_report ? "--cytosine_report --genome_folder ${index} " : ''
        meth_cutoff = params.meth_cutoff ? "--cutoff ${params.meth_cutoff}" : ''
        multicore = ''
        if( task.cpus ){
            // Numbers based on Bismark docs
            ccore = ((task.cpus as int) / 3) as int
            if( ccore > 1 ){
              multicore = "--multicore $ccore"
            }
        }
        buffer = ''
        if( task.memory ){
            mbuffer = (task.memory as nextflow.util.MemoryUnit) - 2.GB
            // only set if we have more than 6GB available
            if( mbuffer.compareTo(4.GB) == 1 ){
              buffer = "--buffer_size ${mbuffer.toGiga()}G"
            }
        }
        if(params.single_end) {
            """
            bismark_methylation_extractor $comprehensive $meth_cutoff \\
                $multicore $buffer $cytosine_report \\
                --bedGraph \\
                --counts \\
                --gzip \\
                -s \\
                --report \\
                $bam
            """
        } else {
            """
            bismark_methylation_extractor $comprehensive $meth_cutoff \\
                $multicore $buffer \\
                --CX_context
                --cytosine_report \\
                --ignore_r2 2 \\
                --ignore_3prime_r2 2 \\
                --bedGraph \\
                --counts \\
                --gzip \\
                -p \\
                --no_overlap \\
                --report \\
                $bam
            """
        }
    }

    ch_bismark_align_log_for_bismark_report
     .join(ch_bismark_dedup_log_for_bismark_report)
     .join(ch_bismark_splitting_report_for_bismark_report)
     .join(ch_bismark_mbias_for_bismark_report)
     .set{ ch_bismark_logs_for_bismark_report }


    /*
     * STEP 6 - Bismark Sample Report
     */
    process bismark_report {
        tag "$name"
        publishDir "${params.outdir}/bismark_reports", mode: params.publish_dir_mode

        input:
        set val(name), file(align_log), file(dedup_log), file(splitting_report), file(mbias) from ch_bismark_logs_for_bismark_report

        output:
        file '*{html,txt}' into ch_bismark_reports_results_for_multiqc

        script:
        """
        bismark2report \\
            --alignment_report $align_log \\
            --dedup_report $dedup_log \\
            --splitting_report $splitting_report \\
            --mbias_report $mbias
        """
    }

    /*
     * STEP 7 - Bismark Summary Report
     */
    process bismark_summary {
        publishDir "${params.outdir}/bismark_summary", mode: params.publish_dir_mode

        input:
        file ('*') from ch_bam_for_bismark_summary.collect()
        file ('*') from ch_bismark_align_log_for_bismark_summary.collect()
        file ('*') from ch_bismark_dedup_log_for_bismark_summary.collect()
        file ('*') from ch_bismark_splitting_report_for_bismark_summary.collect()
        file ('*') from ch_bismark_mbias_for_bismark_summary.collect()

        output:
        file '*{html,txt}' into ch_bismark_summary_results_for_multiqc

        script:
        """
        bismark2summary
        """
    }
} // End of bismark processing block
else {
    ch_bismark_align_log_for_multiqc = Channel.from(false)
    ch_bismark_dedup_log_for_multiqc = Channel.from(false)
    ch_bismark_splitting_report_for_multiqc = Channel.from(false)
    ch_bismark_mbias_for_multiqc = Channel.from(false)
    ch_bismark_reports_results_for_multiqc = Channel.from(false)
    ch_bismark_summary_results_for_multiqc = Channel.from(false)
}


/*
 * Process with bwa-mem and assorted tools
 */
if( params.aligner == 'bwameth' ){
    process bwamem_align {
        tag "$name"
        publishDir "${params.outdir}/bwa-mem_alignments", mode: params.publish_dir_mode,
            saveAs: {filename ->
                if( !params.save_align_intermeds && filename == "where_are_my_files.txt" ) filename
                else if( params.save_align_intermeds && filename != "where_are_my_files.txt" ) filename
                else null
            }

        input:
        set val(name), file(reads) from ch_trimmed_reads_for_alignment
        file bwa_meth_indices from ch_bwa_meth_indices_for_bwamem_align.collect()
        file wherearemyfiles from ch_wherearemyfiles_for_bwamem_align.collect()

        output:
        set val(name), file('*.bam') into ch_bam_for_samtools_sort_index_flagstat, ch_bam_for_preseq, ch_bam_cgmaptools
        file "where_are_my_files.txt"

        script:
        fasta = bwa_meth_indices[0].toString() - '.bwameth' - '.c2t' - '.amb' - '.ann' - '.bwt' - '.pac' - '.sa'
        prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
        """
        bwameth.py \\
            --threads ${task.cpus} \\
            --reference $fasta \\
            $reads | samtools view -bS - > ${prefix}.bam
        """
    }


    /*
     * STEP 4.- samtools flagstat on samples
     */
    if ( params.skip_alignment || params.aligner == 'bwameth' )  
    process samtools_sort_index_flagstat {
        tag "$name"
        publishDir "${params.outdir}/bam_processing", mode: params.publish_dir_mode,
            saveAs: {filename ->
                if(filename.indexOf("report.txt") > 0) "logs/$filename"
                else if( (!params.save_align_intermeds && !params.skip_deduplication && !params.rrbs).every() && filename == "where_are_my_files.txt") filename
                else if( (params.save_align_intermeds || params.skip_deduplication || params.rrbs).any() && filename != "where_are_my_files.txt") filename
                else null
            }

        input:
        set val(name), file(bam) from ch_bam_for_samtools_sort_index_flagstat
        file wherearemyfiles from ch_wherearemyfiles_for_samtools_sort_index_flagstat.collect()

        output:
        set val(name), file("${bam.baseName}.sorted.bam") into ch_indep_bam_sorted, ch_bam_sorted_for_markDuplicates
        set val(name), file("${bam.baseName}.sorted.bam.bai") into ch_bam_index, ch_indep_bam_index
        file "${bam.baseName}_flagstat_report.txt" into ch_flagstat_results_for_multiqc
        file "${bam.baseName}_stats_report.txt" into ch_samtools_stats_results_for_multiqc
        file "where_are_my_files.txt"

        script:
        def avail_mem = task.memory ? ((task.memory.toGiga() - 6) / task.cpus).trunc() : false
        def sort_mem = avail_mem && avail_mem > 2 ? "-m ${avail_mem}G" : ''
        """
        samtools sort $bam \\
            -@ ${task.cpus} $sort_mem \\
            -o ${bam.baseName}.sorted.bam
        samtools index ${bam.baseName}.sorted.bam
        samtools flagstat ${bam.baseName}.sorted.bam > ${bam.baseName}_flagstat_report.txt
        samtools stats ${bam.baseName}.sorted.bam > ${bam.baseName}_stats_report.txt
        """
    }

    /*
     * STEP 5 - Mark duplicates
     */
    if( params.skip_deduplication || params.rrbs ) {
        ch_bam_sorted_for_markDuplicates.into { ch_bam_dedup_for_methyldackel; ch_bam_dedup_for_qualimap; ch_bam_cgmaptools }
        ch_bam_index.set { ch_bam_index_for_methyldackel }
        ch_markDups_results_for_multiqc = Channel.from(false)
    } else {
        process markDuplicates {
            tag "$name"
            publishDir "${params.outdir}/bwa-mem_markDuplicates", mode: params.publish_dir_mode,
                saveAs: {filename -> filename.indexOf(".bam") == -1 ? "logs/$filename" : "$filename"}

            input:
            set val(name), file(bam) from ch_bam_sorted_for_markDuplicates
                        

            output:
            set val(name), file("${name}.markDups.bam") into ch_bam_dedup_for_methyldackel, ch_bam_dedup_for_qualimap, ch_bam_cgmaptools
            set val(name), file("${bam.baseName}.markDups.bam.bai") into ch_bam_index_for_methyldackel //ToDo check if this correctly overrides the original channel
            file "${bam.baseName}.markDups_metrics.txt" into ch_markDups_results_for_multiqc

            script:
            if( !task.memory ){
                log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
                avail_mem = 3
            } else {
                avail_mem = task.memory.toGiga()
            }
            """
            picard -Xmx${avail_mem}g MarkDuplicates \\
                INPUT=$bam \\
                OUTPUT=${bam.baseName}.markDups.bam \\
                METRICS_FILE=${bam.baseName}.markDups_metrics.txt \\
                REMOVE_DUPLICATES=false \\
                ASSUME_SORTED=true \\
                PROGRAM_RECORD_ID='null' \\
                VALIDATION_STRINGENCY=LENIENT
            samtools index ${bam.baseName}.markDups.bam
            """
        }
    }

    /*
     * STEP 6 - extract methylation with MethylDackel
     */

    process methyldackel {
        tag "$name"
        publishDir "${params.outdir}/MethylDackel", mode: params.publish_dir_mode

        input:
        set val(name),
            file(bam),
            file(bam_index),
            file(fasta),
            file(fasta_index) from ch_bam_dedup_for_methyldackel
            .join(ch_bam_index_for_methyldackel)
            .combine(ch_fasta_for_methyldackel)
            .combine(ch_fasta_index_for_methyldackel)


        output:
        file "${bam.baseName}*" into ch_methyldackel_results_for_multiqc

        script:
        all_contexts = params.comprehensive ? '--CHG --CHH' : ''
        min_depth = params.min_depth > 0 ? "--minDepth ${params.min_depth}" : ''
        ignore_flags = params.ignore_flags ? "--ignoreFlags" : ''
        methyl_kit = params.methyl_kit ? "--methylKit" : ''
        """
        MethylDackel extract $all_contexts $ignore_flags $methyl_kit $min_depth $fasta $bam
        MethylDackel mbias $all_contexts $ignore_flags $fasta $bam ${bam.baseName} --txt > ${bam.baseName}_methyldackel.txt
        """
    }

} // end of bwa-meth if block
else {
    ch_flagstat_results_for_multiqc = Channel.from(false)
    ch_samtools_stats_results_for_multiqc = Channel.from(false)
    ch_markDups_results_for_multiqc = Channel.from(false)
    ch_methyldackel_results_for_multiqc = Channel.from(false)
}


/*BismarkIndex_for methXtract */

if( params.aligner == 'none' ){
    process makeBismarkIndex_2 {
        publishDir path: { params.save_reference ? "${params.outdir}/reference_genome" : params.outdir },
                   saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta_bismarkIndex_2

        output:
        file "BismarkIndex" into ch_bismark_index_for_bismark_methXtract_2

        script:
        """
        mkdir BismarkIndex
        cp $fasta BismarkIndex/
        bismark_genome_preparation --bowtie2 BismarkIndex
        """
    }
}

/* Deduplicate for BAM file input */

if (params.aligner == 'none') {
    process markDuplicates_bam_input {
        tag "${name}"
        publishDir "${params.outdir}/bam_markDuplicates", mode: params.publish_dir_mode,
            saveAs: {filename -> "$filename"}

    input:
        //set bam from ch_indep_bam_for_processing
        set val(name), file(bam) from ch_indep_bam_for_processing      

    output:
        set val(name), file("*.markDups.bam") into ch_bam_resort, ch_bam_dedup_for_qualimap_indep
        set val(name), file("*.markDups.bam.bai") into ch_bam_index_indep 
        file "*.markDups_metrics.txt" into ch_markDups_results_for_multiqc_indep
            
    script:
        
        //name = bam[0].toString() - ~/(.bam)?$/
        
        if( !task.memory ){
            log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
            avail_mem = 3
            } else {
                avail_mem = task.memory.toGiga()
            }

            """
            picard -Xmx${avail_mem}g MarkDuplicates \\
                INPUT=$bam \\
                OUTPUT=${name}.markDups.bam \\
                METRICS_FILE=${name}.markDups_metrics.txt \\
                REMOVE_DUPLICATES=false \\
                ASSUME_SORTED=true \\
                PROGRAM_RECORD_ID='null' \\
                VALIDATION_STRINGENCY=LENIENT
            samtools index ${name}.markDups.bam
            """
        }
}

/*Sort bam file by RG
*/
if (params.aligner == 'none') {
    process sort_bam_RG {
        tag "${name}"
        publishDir "${params.outdir}/bam_sort_RG", mode: params.publish_dir_mode 
                
        input:
        set val(name), file(bam) from ch_bam_resort

        output:
        set val(name), file("*.sorted.bam") into ch_bam_meth_call

        script:
                """
                samtools sort -n -@ 6 -m 3G $bam -o ${name}.sorted.bam 
                """
        }
}
/*Bismark methylation calling to produce cytosine report
*/
if (params.aligner == 'none') {
    process bismark_methXtract_2 {
        tag "${name}"
        publishDir "${params.outdir}/bismark_methylation_calls", mode: params.publish_dir_mode

                    input:
                    set val(name), file(bam) from ch_bam_meth_call
                    file index from ch_bismark_index_for_bismark_methXtract_2

                    output:
                    set val(name), file("*splitting_report.txt") into ch_bismark_splitting_report_for_bismark_report_2, ch_bismark_splitting_report_for_bismark_summary_2, ch_bismark_splitting_report_for_multiqc_2
                    set val(name), file("*.M-bias.txt") into ch_bismark_mbias_for_bismark_report_2, ch_bismark_mbias_for_bismark_summary_2, ch_bismark_mbias_for_multiqc_2
                    set val (name), file("*.*_report.txt") into ch_bismark_to_cgmap, ch_view_bs
                    file '*.{png,gz}' 

        script:
        multicore = ''
        if( task.cpus ){
            // Numbers based on Bismark docs
            ccore = ((task.cpus as int) / 3) as int
            if( ccore > 1 ){
              multicore = "--multicore $ccore"
            }
        }
        buffer = ''
        if( task.memory ){
            mbuffer = (task.memory as nextflow.util.MemoryUnit) - 2.GB
            // only set if we have more than 6GB available
            if( mbuffer.compareTo(4.GB) == 1 ){
              buffer = "--buffer_size ${mbuffer.toGiga()}G"
            }
        }
//
            """
            bismark_methylation_extractor --genome $index --cytosine_report --CX_context\\
                $multicore $buffer \\
                --ignore_r2 2 \\
                --ignore_3prime_r2 2 \\
                --counts \\
                -p \\
                --no_overlap \\
                --report \\
                $bam
            """
                    }
                }

/*Bismark to cgmaptools
*/
/*if( params.aligner = 'bismark' ){
   ch_bismark_to_cgmap_OG = ch_bismark_to_cgmap
} */
if ( params.skip_alignment ) {
    process CX_report_to_cgmap {
        tag "$name"
        publishDir "${params.outdir}/cgmaptools_methyl_bismark", mode: params.publish_dir_mode,
            saveAs: {filename -> "$filename"}
        
    input:
        set val(name), 
            file(cgmap) from ch_bismark_to_cgmap
    
    output:
    set val(name), file("*.CGmap") into ch_cgmap_PE, ch_cgmap_to_extract_CHR_PE, ch_cgmap_methkit_PE
        
    script:
        """
        cgmaptools convert bismark2cgmap -i $cgmap -o ${name}_meth_call.CGmap
        """ 
    }
}
/* STEP Sort input BAM file
*/
if (params.skip_alignment) {
    ch_sorted_bam = Channel.from(false)
} else {
    process sort_bam_file {
        tag "$name"
        publishDir "${params.outdir}/sorted_bam", mode: params.publish_dir_mode,
            saveAs: {filename -> "sorted_bam/$filename"}

    input:
        set val(name), file(bam) from ch_bam_cgmaptools

    output:
    set val(name), file("*.sorted.bam") into ch_sorted_bam, ch_sorted_for_preseq

    script:
        """
        samtools sort -@ 6 -m 3G -o ${name}.sorted.bam $bam
        """
    }
}

/* 
 * STEP NEW!! methylation calling - CGmaptools
 */
if (params.skip_alignment) {
    ch_cgmap_CG_file = Channel.from(false)
} else { 
    process cgmap_meth_calling {
            tag "$name"
            publishDir "${params.outdir}/cgmaptools", mode: params.publish_dir_mode,
                saveAs: {filename -> "cgmap_methyl_call/$filename"}
            
        input:
            set val(name), 
                file(bam), 
                file(fasta) from ch_sorted_bam
                .combine(ch_fasta_for_cgmaptools)
        
        output:
        set val(name), file("*.CGmap.gz") into ch_cgmap_CG_file, ch_cgmap_to_extract_CHR, ch_cgmap_for_MKit
        set val(name), file("*.ATCGmap.gz") into ch_cgmap_ATCG_file, ch_cgmap_ATCG_to_extract_CHR 
            
        script:
            """
            cgmaptools convert bam2cgmap -b $bam -g $fasta -o ${name}_meth_call   
            """ 
        }
}
/*STEP NEW2!! CGmap_visualization ATCGmap
 */
if (params.skip_alignment) {
    ch_cgmap_visualization_cove = Channel.from(false)
} else {
    
process cgmap_visualisation_atcgmap {
    tag "$name"
    publishDir "${params.outdir}/cgmaptools", mode: 'copy',
    saveAs: {filename -> "cgmap_figures_data/$filename" }
    
    input:
    set val(name), file(atcgmap) from ch_cgmap_ATCG_file
    
    output:
    /*set val(CGmap), file("*.pdf") into ch_cgmap_visualization */
    file "*.pdf" into ch_cgmap_visualization_cove   //maybe later add to channel to create the html file??//
    file "*.data" into ch_cgmap_data
    //parts of script eg. c -> discuss what this should be or should request input from user?? //
    
    script:
    """
    cgmaptools oac bin -i $atcgmap -f pdf -p ${name} -t ${name} > ${name}_oac_bin.data

    cgmaptools oac stat -i $atcgmap -f pdf -p ${name} > ${name}_oac_stat.data
    """
    }
}

/*STEP NEW3!! CGmap_visualization CGmap
 */
 if (params.skip_alignment) {
    ch_cgmap_CG_file = ch_cgmap_PE
 }
    process cgmap_visualisation_cgmap {
        tag "$name"
        publishDir "${params.outdir}/cgmaptools", mode: 'copy',
        saveAs: {filename -> "cgmap_figures_data/$filename" }
        
        input:
        set val(name), file(cgmap) from ch_cgmap_CG_file
        
        output:
        /*set val(CGmap), file("*.pdf") into ch_cgmap_visualization */
        file "*.pdf" into ch_cgmap_vis_figure
        file "*.data" into ch_cgmap_mec_stat

        script:
        
        """
        cgmaptools mec stat -i $cgmap -f pdf -p ${name} > ${name}_mec_stat.data

        cgmaptools mbin -i $cgmap -c 10  -f pdf -p ${name} -t ${name} > ${name}_mbin.data

        cgmaptools mstat -i $cgmap -c 10 -f pdf -p ${name} -t ${name} > ${name}_mstat.data
        """
    }

/*STEP NEW3!! Convert_cgmap_methKit
 */
if (params.aligner == 'none') {
    ch_cgmap_for_MKit = ch_cgmap_methkit_PE
 }
    process cgmap_conversion_methkit {
        tag "$name"
        publishDir "${params.outdir}/methKit", mode: 'copy',
        saveAs: {filename -> "methyl_kit/$filename" }
        
        input:
        set val(name), file(cgmap) from ch_cgmap_for_MKit
        
        output:
        set val(name), file("*.MKit") into ch_cgmap_to_MKit 
        script:

        """
        python ${baseDir}/CGMap_ToMethylKit.py $cgmap > ${name}.MKit
        """
        } 
 
/*STEP NEW4!! Run_MKit 
 */  
process get_stats_mkit {
    tag "$name"
    publishDir "${params.outdir}/methKit", mode: 'copy',
    saveAs: {filename -> "methyl_kit/$filename" } 
    
    input:
    set val(name), file(methkit) from ch_cgmap_to_MKit
    
    output:
    set val(name), file("*_hist.pdf") into ch_MKit_results_hist
    set val(name), file("*_cov.pdf") into ch_MKit_results_cov
    
    script:
    
    """
    Rscript ${baseDir}/methylkit_rscript.r $methkit ${name}
    """
    } 
/*STEP SELECT only CHR
*/
 if (params.skip_alignment) {
    ch_cgmap_to_extract_CHR = ch_cgmap_to_extract_CHR_PE
 }
process extract_chr_cgmap 
{
    tag "$name"
    publishDir "${params.outdir}/cgmaptools", mode: params.publish_dir_mode,
        saveAs: {filename -> "cgmap_methyl_call_CHR/$filename"}

    input:
    set val(name), 
    file(cgmap) from ch_cgmap_to_extract_CHR
           
    output:
    
    set val(name), file("*.CGmap") into ch_cgmap_CG_cgm_chr_f
    
    shell:
    '''
    awk ' {OFS ="\\t"} ($1~/^([0-9|X|Y|W|Z]+)$/) {print "chr"$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16}' !{cgmap} | sed 's/--/NaN/g' > !{name}_CHR.CGmap
    '''
}
 /*zcat !{cgmap} |
/*STEP SELECT only CHR 2
*/
if (params.skip_alignment) {
    ch_cgmap_ATCG_to_extract_CHR = Channel.from(false)
} else {
process extract_chr_cgmap_atcg 
{
    tag "$name"
    publishDir "${params.outdir}/cgmaptools", mode: params.publish_dir_mode,
        saveAs: {filename -> "cgmap_methyl_call_CHR/$filename"}

    input:
    set val(name), 
    file(atcgmap) from ch_cgmap_ATCG_to_extract_CHR
       
    output:
    set val(name),
    file("*.ATCGmap.gz") into ch_cgmap_atcgmap_chr 

    shell:
    '''
    zcat !{atcgmap} | awk ' {OFS ="\\t"} ($1~/^([0-9|X|Y|W|Z]+)$/) {print "chr"$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16}' | gzip > !{name}_CHR.ATCGmap.gz
    '''
}
}
/*STEP NEW2!! CGmap_visualization ATCGmap_SORTED_CHR
 */
if (params.skip_alignment) {
    ch_cgmap_atcgmap_chr = Channel.from(false)
} else {
process cgmap_visualisation_atcgmap_chr {
    tag "$name"
    publishDir "${params.outdir}/cgmaptools", mode: 'copy',
    saveAs: {filename -> "cgmap_figures_data_CHR/$filename" }
    
    input:
    set val(name), file(atcgmap_chr) from ch_cgmap_atcgmap_chr
    
    output:
    file "${name}.OverallCovInBins.pdf" into ch_cgmap_visualization_cove_chr   //maybe later add to channel to create the html file??//
    file "${name}_oac_bin.data" into ch_cgmap_oac_bin_data_chr
    file "${name}_oac_stat.data" into ch_cgmap_oac_stat_data_chr
    //parts of script eg. c -> discuss what this should be or should request input from user?? //
    
    script:
    """
    cgmaptools oac bin -i $atcgmap_chr -f pdf -p ${name} -t ${name} > ${name}_oac_bin.data

    cgmaptools oac stat -i $atcgmap_chr -f pdf -p ${name} > ${name}_oac_stat.data
    """
    }
}
/*STEP NEW3!! CGmap_visualization CGmap_SORTED_CHR 
 */
     process visualisation_cgmap_sorted_chr {
        tag "$name"
        publishDir "${params.outdir}/cgmaptools", mode: 'copy',
        saveAs: {filename -> "cgmap_figures_data_CHR/$filename" }
        
        input:
        set val(name), file(cgmap_chr) from ch_cgmap_CG_cgm_chr_f

        output:
        set val(name),
        file("*.pdf") into ch_cgmap_CHR_figures
        file "*_mstat.data" into ch_cgmap_CHR_mstat
        

        script:
        """
        cgmaptools mec stat -i $cgmap_chr -f pdf -p ${name} > ${name}_mec_stat.data
        cgmaptools mbin -i $cgmap_chr -c 10  -f pdf -p ${name} -t ${name} > ${name}_CHR_mbin.data
        cgmaptools mstat -i $cgmap_chr -c 10 -f pdf -p ${name} -t ${name} > ${name}_mstat.data
        """
        }

/* STEP 8 - Qualimap
 */

if (params.skip_alignment) {
    ch_bam_dedup_for_qualimap_indep.set { ch_bam_dedup_for_qualimap }
}
process qualimap {
    tag "$name"
    publishDir "${params.outdir}/qualimap", mode: params.publish_dir_mode

    input:
    set val(name), file(bam) from ch_bam_dedup_for_qualimap

    output:
    file "${bam.baseName}_qualimap" into ch_qualimap_results_for_multiqc

    script:
    gcref = params.genome.toString().startsWith('GRCh') ? '-gd HUMAN' : ''
    gcref = params.genome.toString().startsWith('GRCm') ? '-gd MOUSE' : ''
    def avail_mem = task.memory ? ((task.memory.toGiga() - 6) / task.cpus).trunc() : false
    def sort_mem = avail_mem && avail_mem > 2 ? "-m ${avail_mem}G" : ''
    """
    samtools sort $bam \\
        -@ ${task.cpus} $sort_mem \\
        -o ${bam.baseName}.sorted.bam
    qualimap bamqc $gcref \\
        -bam ${bam.baseName}.sorted.bam \\
        -outdir ${bam.baseName}_qualimap \\
        --collect-overlap-pairs \\
        --java-mem-size=${task.memory.toGiga()}G \\
        -nt ${task.cpus}
    """
}

/*
 * STEP 9 - preseq
 */
/*process preseq {
    tag "$name"
    publishDir "${params.outdir}/preseq", mode: 'copy'

    input:
    set val(name), file(bam) from ch_sorted_for_preseq

    output:
    file "${bam.baseName}.ccurve.txt" into preseq_results

    script:
    def avail_mem = task.memory ? ((task.memory.toGiga() - 6) / task.cpus).trunc() : false
    def sort_mem = avail_mem && avail_mem > 2 ? "-m ${avail_mem}G" : ''
    """
     preseq lc_extrap -v -B $bam -o ${name}.ccurve.txt
    """
}

/*
 * STEP 10 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: params.publish_dir_mode

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    file ('fastqc/*') from ch_fastqc_results_for_multiqc.collect().ifEmpty([])
    file ('trimgalore/*') from ch_trim_galore_results_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_align_log_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_dedup_log_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_splitting_report_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_mbias_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_reports_results_for_multiqc.collect().ifEmpty([])
    file ('bismark/*') from ch_bismark_summary_results_for_multiqc.collect().ifEmpty([])
    file ('samtools/*') from ch_flagstat_results_for_multiqc.flatten().collect().ifEmpty([])
    file ('samtools/*') from ch_samtools_stats_results_for_multiqc.flatten().collect().ifEmpty([])
    file ('picard/*') from ch_markDups_results_for_multiqc.flatten().collect().ifEmpty([])
    file ('methyldackel/*') from ch_methyldackel_results_for_multiqc.flatten().collect().ifEmpty([])
    /*file ('qualimap/*') from ch_qualimap_results_for_multiqc.collect().ifEmpty([])*/
    /*file ('preseq/*') from preseq_results.collect().ifEmpty([])*/
    file ('software_versions/*') from ch_software_versions_yaml_for_multiqc.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = ''
    rfilename = ''
    if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
        rtitle = "--title \"${workflow.runName}\""
        rfilename = "--filename " + workflow.runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report"
    }
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    """
    multiqc -f $rtitle $rfilename $custom_config_file . \\
        -m custom_content -m picard -m qualimap -m bismark -m samtools -m preseq -m cutadapt -m fastqc
    """
}

/*
 * STEP 11 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file output_docs from ch_output_docs
    file images from ch_output_docs_images

    output:
    file 'results_description.html'

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

workflow.onError {
    // Print unexpected parameters - easiest is to just rerun validation
    NfcoreSchema.validateParameters(params, json_schema, log)
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = 'hostname'.execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error '====================================================\n' +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            '============================================================'
                }
            }
        }
    }
}
