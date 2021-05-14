library(methylKit) #load files
file.list=list("pig_rrbs_METcall.CGmap.gz.Mkit")
myobj=methRead(file.list,sample.id=list("s1"),assembly="gg",treatment=c(0))
save.image()
#produce methylation histogram
pdf('Sample1_histogram.pdf')
getMethylationStats(myobj[[1]],plot=T,both.strands=F)
pdf('Sample1_cov.pdf')
getCoverageStats(myobj[[1]],plot=T,both.strands=F)
dev.off()
