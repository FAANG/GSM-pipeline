FROM nfcore/base:latest
LABEL authors="Phil Ewels" \
      description="Docker image containing all software requirements for the nf-core/methylseq pipeline"

# Install libtbb system dependency for bowtie2
RUN apt-get update \
      && apt-get install -y apt-utils && apt-get install -y curl \
      && apt-get install -y  build-essential \
      && apt-get install -y gcc\
      && apt-get install -y libtbb-dev \
      && apt-get install -y zlib1g-dev\
      && apt-get clean -y \
      && rm -rf /var/lib/apt/lists/* 
      

# Install the conda environment
COPY environment.yml /
RUN conda env create --quiet -f /environment.yml 

# Add conda installation dir to PATH (instead of doing 'conda activate')
ENV PATH /opt/conda/envs/nf-core-methylseq-1.6/bin:$PATH

RUN git clone --branch v0.1.2 --depth 1 https://github.com/guoweilong/cgmaptools.git /usr/local/src/cgmaptools && \
    bash -c 'cd /usr/local/src/cgmaptools && ./install.sh' && \
    bash -c 'ln -s /usr/local/src/cgmaptools/cgmaptools /usr/local/bin'
    bash -c 'ln -s /usr/local/src/cgmaptools/bin usr/local/bin/'

# Dump the details of the installed packages to a file for posterity
RUN conda env export --name nf-core-methylseq-1.6 > nf-core-methylseq-1.6.yml
