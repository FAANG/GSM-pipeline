FROM nfcore/base:latest

# 
RUN apt-get update \
      && apt-get install -y libtbb-dev \
      && apt-get clean -y \
      && rm -rf /var/lib/apt/lists/*

COPY environment.yml /
RUN conda env create --quiet -f /environment.yml && conda clean -a

ENV PATH /opt/conda/envs/nf-core-methylseq-1.6/bin:$PATH
# Dump the details of the installed packages to a file for posterity
RUN conda env export --name nf-core-methylseq-1.6 > nf-core-methylseq-1.6.yml

RUN git clone --branch v0.1.2 --depth 1 https://github.com/guoweilong/cgmaptools.git /usr/local/src/cgmaptools && \
    bash -c 'cd /usr/local/src/cgmaptools && ./install.sh' && \
    bash -c 'ln -s /usr/local/src/cgmaptools/cgmaptools /usr/local/bin'
