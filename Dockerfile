FROM nfcore/base:1.9

COPY environment.yml /
RUN conda env create -f /environment.yml && conda clean -a
RUN rm /environment.yml

ENV PATH /opt/conda/envs/nf-core-methylseq-1.4/bin:$PATH

RUN git clone --branch v0.1.2 --depth 1 https://github.com/guoweilong/cgmaptools.git /usr/local/src/cgmaptools && \
    bash -c 'cd /usr/local/src/cgmaptools && ./install.sh' && \
    bash -c 'ln -s /usr/local/src/cgmaptools/cgmaptools /usr/local/bin'

