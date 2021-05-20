library(methylKit) #load files
args = commandArgs(trailingOnly=TRUE)

file.list=list(args[1])
myobj=methRead(file.list,sample.id=list(paste0(args[2])),assembly="ss",treatment=c(0))
save.image()
#produce methylation histogram
pdf('(paste0(args[2]))_hist.pdf')
getMethylationStats(myobj[[1]],plot=T,both.strands=F)
pdf('(paste0(args[2]))_cov.pdf')
getCoverageStats(myobj[[1]],plot=T,both.strands=F)
dev.off()
