package joshua.discriminative.feature_related.feature_template;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;

import joshua.corpus.vocab.SymbolTable;
import joshua.decoder.ff.tm.Rule;
import joshua.decoder.hypergraph.HGNode;
import joshua.discriminative.DiscriminativeSupport;



public class TMFT extends AbstractFeatureTemplate {

	SymbolTable symbolTbl;	
	
	public TMFT(SymbolTable symbolTbl){
		this.symbolTbl = symbolTbl;		
		
		System.out.println("TM template");
	}
	
	
	public void getFeatureCounts(Rule rule, List<HGNode> antNodes, HashMap<String, Double> featureTbl, HashSet<String> restrictedFeatureSet, double scale) {
		
		if(rule != null){			
			String key =  rule.toStringWithoutFeatScores(symbolTbl);//TODO
			if(restrictedFeatureSet == null || restrictedFeatureSet.contains(key)==true){
				DiscriminativeSupport.increaseCount(featureTbl, key, scale);
				//System.out.println("key is " + key +"; lhs " + symbolTbl.getWord(rl.getLHS()));	//System.exit(0);
			}
			
		}
		
	}


}