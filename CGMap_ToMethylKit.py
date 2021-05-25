import sys
import gzip

print("chrBase" + "\t" + "chr" + "\t" + "base" + "\t" + "strand" + "\t" + "coverage" + "\t" + "freqC" + "\t" + "freqT")
with gzip.open(sys.argv[1],'rb') as CGmap:
    for call in CGmap:
        chr, strand, pos, type, dinucleotide, perc_C, mC, cov = call.strip().split()
        if dinucleotide == "CG":
            outlist=[]
            if strand == "C":
                strand="F"
            else:
                strand="R"
            perc_C=float(perc_C)*100
            perc_T=100-(perc_C)
            outlist.append(str("chr"+chr+"."+pos))
            outlist.append(str("chr"+chr))
            outlist.append(str(pos))
            outlist.append(strand)
            outlist.append(str(cov))
            outlist.append(str(perc_C))
            outlist.append(str(perc_T))
            print("\t".join(outlist))