/* This file is part of the Joshua Machine Translation System.
 * 
 * Joshua is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free
 * Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */
package joshua.decoder.ff.lm;

import java.util.ArrayList;
import java.util.List;
import java.util.logging.Logger;

import joshua.corpus.vocab.SymbolTable;
import joshua.decoder.chart_parser.SourcePath;
import joshua.decoder.ff.DefaultStatefulFF;
import joshua.decoder.ff.state_maintenance.DPState;
import joshua.decoder.ff.state_maintenance.NgramDPState;
import joshua.decoder.ff.tm.Rule;
import joshua.decoder.hypergraph.HGNode;


/**
 * This class performs the following:
 * <ol> 
 * <li> Gets the additional LM score due to combinations of small
 *      items into larger ones by using rules
 * <li> Gets the LM state 
 * <li> Gets the left-side LM state estimation score
 * </ol>
 * 
 * <em>Note</em>: the LMGrammar returns LogP; while the LanguageModelFF
 * needs to return cost (i.e., -LogP)
 *
 * @author Zhifei Li, <zhifei.work@gmail.com>
 * @version $LastChangedDate$
 */
public class LanguageModelFF extends DefaultStatefulFF {
	
	/** Logger for this class. */
	private static final Logger logger = Logger.getLogger(LanguageModelFF.class.getName());
	
	private final String START_SYM="<s>";
	private final int START_SYM_ID;
	private final String STOP_SYM="</s>";
	private final int STOP_SYM_ID;
	
	
	/* These must be static (for now) for LMGrammar, but they shouldn't be! in case of multiple LM features */
	static String BACKOFF_LEFT_LM_STATE_SYM="<lzfbo>";
	static public int BACKOFF_LEFT_LM_STATE_SYM_ID;//used for equivelant state
	static String NULL_RIGHT_LM_STATE_SYM="<lzfrnull>";
	static public int NULL_RIGHT_LM_STATE_SYM_ID;//used for equivelant state
	
	private final boolean addStartAndEndSymbol = true;
	
	/** 
	 * N-gram language model. We assume the language model is
	 * in ARPA format for equivalent state:
	 * 
	 * <ol>
	 * <li>We assume it is a backoff lm, and high-order ngram
	 *     implies low-order ngram; absense of low-order ngram
	 *     implies high-order ngram</li>
	 * <li>For a ngram, existence of backoffweight => existence
	 *     a probability Two ways of dealing with low counts:
	 *     <ul>
	 *       <li>SRILM: don't multiply zeros in for unknown
	 *           words</li>
	 *       <li>Pharaoh: cap at a minimum score exp(-10),
	 *           including unknown words</li>
	 *     </ul>
	 * </li>
	 */
	private final NGramLanguageModel lmGrammar;
	
	/**
	 * We always use this order of ngram, though the LMGrammar
	 * may provide higher order probability.
	 */
	private final int ngramOrder;// = 3;
	//boolean add_boundary=false; //this is needed unless the text already has <s> and </s>
	
	/** Symbol table that maps between Strings and integers. */
	private final SymbolTable symbolTable;
	
	
	/** stateID is any integer exept -1
	 **/
	public LanguageModelFF(int stateID, int featID, int ngramOrder, SymbolTable psymbol, NGramLanguageModel lmGrammar, double weight) {
		super(stateID, weight, featID);
		this.ngramOrder = ngramOrder;
		this.lmGrammar  = lmGrammar;
		this.symbolTable = psymbol;
		this.START_SYM_ID = psymbol.addTerminal(START_SYM);
		this.STOP_SYM_ID = psymbol.addTerminal(STOP_SYM);
		
		LanguageModelFF.BACKOFF_LEFT_LM_STATE_SYM_ID = symbolTable.addTerminal(BACKOFF_LEFT_LM_STATE_SYM);
		LanguageModelFF.NULL_RIGHT_LM_STATE_SYM_ID = symbolTable.addTerminal(NULL_RIGHT_LM_STATE_SYM);
		
		logger.info("LM feature, with an order=" + ngramOrder);
	}
	


	public double transition(Rule rule, List<HGNode> antNodes, int spanStart, int spanEnd, SourcePath srcPath) {
		return computeTransition(rule.getEnglish(), antNodes);
	}

	
	public double finalTransition(HGNode antNode, int spanStart, int spanEnd, SourcePath srcPath) {
		return computeFinalTransition((NgramDPState)antNode.getDPState(this.getStateID()));
	}
	
	

	/**will consider all the complete ngrams, 
	 * and all the incomplete-ngrams that will have sth fit into its left side*/
	public double estimate(Rule rule) {
		return estimateRuleProb(rule.getEnglish());
	}
	


	public double estimateFutureCost(Rule rule, DPState curDPState) {
		return estimateStateProb((NgramDPState)curDPState, false, false);
	}



	
	/**when calculate transition prob: when saw a <bo>, then need to add backoff weights, start from non-state words
	 * */
	private double computeTransition(int[] enWords,	List<HGNode> antNodes) {
				
		ArrayList<Integer> currentNgram   = new ArrayList<Integer>();
		double             transitionCost = 0.0;
		
		for (int c = 0; c < enWords.length; c++) {
			int curID = enWords[c];
			if (symbolTable.isNonterminal(curID)) {				
				int index = symbolTable.getTargetNonterminalIndex(curID);
			
				NgramDPState state = (NgramDPState) antNodes.get(index).getDPState(this.getStateID());
				List<Integer> leftContext = state.getLeftLMStateWords();
				List<Integer> rightContext = state.getRightLMStateWords();
				if (leftContext.size() != rightContext.size() ) {
					throw new RuntimeException("LMModel.lookup_words1_equv_state: left and right contexts have unequal lengths");
				}
				
				//================ left context
				for (int i = 0; i < leftContext.size(); i++) {
					int t = leftContext.get(i);
					currentNgram.add(t);
					
					//always calculate cost for <bo>: additional backoff weight
					if (t == BACKOFF_LEFT_LM_STATE_SYM_ID) {
						int numAdditionalBackoffWeight = currentNgram.size() - (i+1);//number of non-state words
						
						//compute additional backoff weight
						transitionCost	-= this.lmGrammar.logProbOfBackoffState(currentNgram, currentNgram.size(), numAdditionalBackoffWeight);
						
						if (currentNgram.size() == this.ngramOrder) {
							currentNgram.remove(0);
						}
					} else if (currentNgram.size() == this.ngramOrder) {
						// compute the current word probablity, and remove it
						transitionCost -= this.lmGrammar.ngramLogProbability(currentNgram, this.ngramOrder);
						
						currentNgram.remove(0);
					}
					
				}
				
				//================  right context
				//note: left_state_org_wrds will never take words from right context because it is either duplicate or out of range
				//also, we will never score the right context probablity because they are either duplicate or partional ngram
				int tSize = currentNgram.size();
				for (int i = 0; i < rightContext.size(); i++) {
					// replace context
					currentNgram.set(tSize - rightContext.size() + i, rightContext.get(i) );
				}
			
			} else {//terminal words
				currentNgram.add(curID);
				if (currentNgram.size() == this.ngramOrder) {
					// compute the current word probablity, and remove it
					transitionCost -= this.lmGrammar.ngramLogProbability(currentNgram, this.ngramOrder);
					
					currentNgram.remove(0);
				}
			}
		}
		//===== create tabl
		
		//===== get left euquiv state 
		//double[] lmLeftCost = new double[2];
		//int[] equivLeftState = this.lmGrammar.leftEquivalentState(Support.subIntArray(leftLMStateWrds, 0, leftLMStateWrds.size()),	this.ngramOrder, lmLeftCost);
		
		//transitionCost += lmLeftCost[0];//add finalized cost for the left state words
		return transitionCost;
	}

	private double computeFinalTransition(NgramDPState state) {
		
		double res = 0.0;
		List<Integer> currentNgram = new ArrayList<Integer>();
		List<Integer>   leftContext = state.getLeftLMStateWords();		
		List<Integer>   rightContext = state.getRightLMStateWords();
		if (leftContext.size() != rightContext.size()) {
			throw new RuntimeException(
				"LMModel.compute_equiv_state_final_transition: left and right contexts have unequal lengths");
		}
		
		//================ left context
		if (addStartAndEndSymbol) 
			currentNgram.add(START_SYM_ID);
		
		for (int i = 0; i < leftContext.size(); i++) {
			int t = leftContext.get(i);
			currentNgram.add(t);
			
			if (t == BACKOFF_LEFT_LM_STATE_SYM_ID) {//calculate cost for <bo>: additional backoff weight
				int additional_backoff_weight = currentNgram.size() - (i+1);
				//compute additional backoff weight
				//TOTO: may not work with the case that add_start_and_end_symbol=false
				res -= this.lmGrammar.logProbOfBackoffState(
					currentNgram, currentNgram.size(), additional_backoff_weight);
				
			} else { // partial ngram
				//compute the current word probablity
				if (currentNgram.size() >= 2) { // start from bigram
					res -= this.lmGrammar.ngramLogProbability(
						currentNgram, currentNgram.size());
				}
			}
			if (currentNgram.size() == this.ngramOrder) {
				currentNgram.remove(0);
			}
		}
		
		//================ right context
		//switch context, we will never score the right context probablity because they are either duplicate or partional ngram
		if(addStartAndEndSymbol){
			int tSize = currentNgram.size();
			for (int i = 0; i < rightContext.size(); i++) {
				//replace context
				currentNgram.set(tSize - rightContext.size() + i, rightContext.get(i));
			}
			
			currentNgram.add(STOP_SYM_ID);
			res -= this.lmGrammar.ngramLogProbability(currentNgram, currentNgram.size());
		}
		return res;
	}

	
	//return cost, including partial ngrams
	/*in general: consider all the complete ngrams, and all the incomplete-ngrams that WILL have sth fit into its left side, so
	*if the left side of incomplete-ngrams is a ECLIPS, then ignore the incomplete-ngrams
	*if the left side of incomplete-ngrams is a Non-Terminal, then consider the incomplete-ngrams  
	*if the left side of incomplete-ngrams is boundary of a rule, then consider the incomplete-ngrams*/
	private double estimateRuleProb(int[] enWords) {
		double    estimate   = 0.0;
		boolean   considerIncompleteNgrams = true;
		ArrayList<Integer> words      = new ArrayList<Integer>();
		boolean   skip_start = (enWords[0] == START_SYM_ID);
		
		for (int c = 0; c < enWords.length; c++) {
			int curWrd = enWords[c];
			/*if (c_wrd == Symbol.ECLIPS_SYM_ID) {
				estimate += score_chunk(
					words, consider_incomplete_ngrams, skip_start);
				consider_incomplete_ngrams = false;
				//for the LM bonus function: this simply means the right state will not be considered at all because all the ngrams in right-context will be incomplete
				words.clear();
				skip_start = false;
			} else*/ if (symbolTable.isNonterminal(curWrd)) {
				estimate += scoreChunk(
					words, considerIncompleteNgrams, skip_start);
				considerIncompleteNgrams = true;
				words.clear();
				skip_start = false;
			} else {
				words.add(curWrd);
			}
		}
		estimate += scoreChunk(
			words, considerIncompleteNgrams, skip_start);
		return estimate;
	}
	
	
	//this function is called when left_equiv state is NOT used
	//in state, all the ngrams are incomplete
	//only get the estimation for the left-state
	//get the true prob for right-state, if add_end==true
	private double estimateStateProb(NgramDPState state, boolean addStart, boolean addEnd) {
		double res = 0.0;
		
		List<Integer>   leftContext = state.getLeftLMStateWords();
		
		if (null != leftContext) {
			ArrayList<Integer> list;
			if (addStart == true) {
				list = new ArrayList<Integer>(leftContext.size() + 1);
				list.add(START_SYM_ID);
			} else {
				list = new ArrayList<Integer>(leftContext.size());
			}
			for (int k = 0; k <leftContext.size(); k++) {
				//if(l_context[k]!=Symbol.LM_STATE_OVERLAP_SYM_ID)
					list.add(leftContext.get(k));
			}
			boolean considerIncompleteNgrams = true;
			boolean skip_start = true;
			if (list.get(0) != START_SYM_ID) {
				skip_start = false;
			}
			res += scoreChunk(list, considerIncompleteNgrams, skip_start);
		}
		/*if (add_start == true) {
			System.out.println("left context: " +Symbol.get_string(l_context) + ";prob "+res);
		}*/
		if (addEnd == true) {//only when add_end is true, we get a complete ngram, otherwise, all ngrams in r_state are incomplete and we should do nothing
			List<Integer>    rightContext = state.getRightLMStateWords();
			List<Integer> list = new ArrayList<Integer>(rightContext.size()+1);
			for (int k = 0; k < rightContext.size(); k++) {
				list.add(rightContext.get(k));
			}
			list.add(STOP_SYM_ID);
			double tem = scoreChunk(list, false, false);
			res += tem;
			//System.out.println("right context:"+ Symbol.get_string(r_context) + "; score: "  + tem);
		}
		return res;
	}
	


	private double scoreChunk(List<Integer> words, boolean considerIncompleteNgrams, boolean skipStart) {
		if (words.size() <= 0) {
			return 0.0;
		} else {
			int startIndex;
			if (! considerIncompleteNgrams) {
				startIndex = this.ngramOrder;
			} else if (skipStart) {
				startIndex = 2;
			} else {
				startIndex = 1;
			}
			
			return -this.lmGrammar.sentenceLogProbability(
				words, this.ngramOrder, startIndex);
		}
	}
	
}

