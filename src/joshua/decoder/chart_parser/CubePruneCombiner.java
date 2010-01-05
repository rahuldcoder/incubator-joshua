package joshua.decoder.chart_parser;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.PriorityQueue;

import joshua.decoder.JoshuaConfiguration;
import joshua.decoder.ff.FeatureFunction;
import joshua.decoder.ff.state_maintenance.StateComputer;
import joshua.decoder.ff.tm.Rule;
import joshua.decoder.hypergraph.HGNode;

public class CubePruneCombiner implements Combiner{
	
	private List<FeatureFunction> featureFunctions;
	private List<StateComputer> stateComputers;
	
	public CubePruneCombiner(List<FeatureFunction> featureFunctions, List<StateComputer> stateComputers){
		this.featureFunctions = featureFunctions;
		this.stateComputers = stateComputers;
	}
	
	//BUG:???????????????????? CubePrune will depend on relativeThresholdPruning, but  cell.beamPruner can be null ????????????????
	
	
	

	public void addAxioms(Chart chart, Cell cell, int i, int j, List<Rule> rules, SourcePath srcPath) {
		for (Rule rule : rules) {
			addAxiom(chart, cell, i, j, rule, srcPath);
		}
	}



	public void addAxiom(Chart chart, Cell cell, int i, int j, Rule rule, SourcePath srcPath) {
		cell.addHyperEdgeInCell(
				new ComputeNodeResult(this.featureFunctions, rule, null, i, j, srcPath, stateComputers),
				rule, i, j, null, srcPath);
	}

	
	/** Add complete Items in Chart pruning inside this function */
	// TODO: our implementation do the prunining for each DotItem
	//       under each grammar, not aggregated as in the python
	//       version
	// TODO: the implementation is little bit different from
	//       the description in Liang'2007 ACL paper
	public void combine(Chart chart, Cell cell, int i, int j, List<SuperNode> superNodes, List<Rule> rules, int arity, SourcePath srcPath) {
		
		//combinations: rules, antecent nodes
		//in the paper, combinationHeap is called cand[v]
		PriorityQueue<CubePruneState> combinationHeap =	new PriorityQueue<CubePruneState>();
		
		// rememeber which state has been explored
		HashMap<String,Integer> cubeStateTbl = new HashMap<String,Integer>();
		
		if (null == rules || rules.size() <= 0) {
			return;
		}
		
		//== seed the heap with best node
		Rule currentRule = rules.get(0);
		ArrayList<HGNode> currentAntNodes = new ArrayList<HGNode>();
		for (SuperNode si : superNodes) {
			// TODO: si.nodes must be sorted
			currentAntNodes.add(si.nodes.get(0));
		}
		ComputeNodeResult result =	new ComputeNodeResult(featureFunctions, currentRule, currentAntNodes, i, j, srcPath, stateComputers);
		
		int[] ranks = new int[1+superNodes.size()]; // rule, ant items
		for (int d = 0; d < ranks.length; d++) {
			ranks[d] = 1;
		}
		
		CubePruneState bestState =	new CubePruneState(result, ranks, currentRule, currentAntNodes);
		combinationHeap.add(bestState);
		cubeStateTbl.put(bestState.getSignature(),1);
		// cube_state_tbl.put(best_state,1);
		
		// extend the heap
		Rule   oldRule = null;
		HGNode oldItem = null;
		int    tem_c   = 0;
		while (combinationHeap.size() > 0) {
			
			//========== decide if the top in the heap should be pruned
			tem_c++;
			CubePruneState curState = combinationHeap.poll();
			currentRule = curState.rule;
			currentAntNodes = new ArrayList<HGNode>(curState.antNodes); // critical to create a new list
			//cube_state_tbl.remove(cur_state.get_signature()); // TODO, repeat
			cell.addHyperEdgeInCell(curState.nodeStatesTbl, curState.rule, i, j,curState.antNodes, srcPath); // pre-pruning inside this function
			
			//if the best state is pruned, then all the remaining states should be pruned away
			if (curState.nodeStatesTbl.getExpectedTotalCost() > cell.beamPruner.getCutCost() + JoshuaConfiguration.fuzz1) {
				//n_prepruned += heap_cands.size();
				chart.nPreprunedFuzz1 += combinationHeap.size();
				break;
			}
			
			//========== extend the curState, and add the candidates into the heap
			for (int k = 0; k < curState.ranks.length; k++) {
				
				//GET new_ranks
				int[] newRanks = new int[curState.ranks.length];
				for (int d = 0; d < curState.ranks.length; d++) {
					newRanks[d] = curState.ranks[d];
				}
				newRanks[k] = curState.ranks[k] + 1;
				
				String new_sig = CubePruneState.getSignature(newRanks);
				
				if (cubeStateTbl.containsKey(new_sig) // explored before
				|| (k == 0 && newRanks[k] > rules.size())
				|| (k != 0 && newRanks[k] > superNodes.get(k-1).nodes.size())
				) {
					continue;
				}
				
				if (k == 0) { // slide rule
					oldRule = currentRule;
					currentRule = rules.get(newRanks[k]-1);
				} else { // slide ant
					oldItem = currentAntNodes.get(k-1); // conside k == 0 is rule
					currentAntNodes.set(k-1,
						superNodes.get(k-1).nodes.get(newRanks[k]-1));
				}
				
				CubePruneState tState = new CubePruneState(
						new ComputeNodeResult(featureFunctions, currentRule, 
								currentAntNodes, i, j, srcPath, stateComputers),
					newRanks, currentRule, currentAntNodes);
				
				// add state into heap
				cubeStateTbl.put(new_sig,1);				
				if (result.getExpectedTotalCost() < cell.beamPruner.getCutCost() + JoshuaConfiguration.fuzz2) {
					combinationHeap.add(tState);
				} else {
					//n_prepruned += 1;
					chart.nPreprunedFuzz2 += 1;
				}
				
				// recover
				if (k == 0) { // rule
					currentRule = oldRule;
				} else { // ant
					currentAntNodes.set(k-1, oldItem);
				}
			}
		}
		
	}
	
	

	
//	===============================================================
//	 CubePruneState class
//	===============================================================
		private static class CubePruneState implements Comparable<CubePruneState> {
			int[]             ranks;
			ComputeNodeResult nodeStatesTbl;
			Rule              rule;
			List<HGNode> antNodes;
			
			public CubePruneState(ComputeNodeResult state, int[] ranks, Rule rule, 
					ArrayList<HGNode> antecedents)
			{
				this.nodeStatesTbl = state;
				this.ranks           = ranks;
				this.rule            = rule;
				// create a new vector is critical, because
				// currentAntecedents will change later
				this.antNodes = new ArrayList<HGNode>(antecedents);
			}
			
			
			private static String getSignature(int[] ranks2) {
				StringBuffer sb = new StringBuffer();
				if (null != ranks2) {
					for (int i = 0; i < ranks2.length; i++) {
						sb.append(' ').append(ranks2[i]);
					}
				}
				return sb.toString();
			}
			
			
			private String getSignature() {
				return getSignature(ranks);
			}
			
			
			/**
			 * Compares states by expected cost, allowing states
			 * to be sorted according to their natural order.
			 * 
			 * @param another State to which this state will be compared
			 * @return -1 if this state's expected cost is less
			 *            than that stat's expected cost,
			 *         0  if this state's expected cost is equal
			 *            to that stat's expected cost,
			 *         +1 if this state's expected cost is
			 *            greater than that stat's expected cost
			 */
			public int compareTo(CubePruneState another) {
				if (this.nodeStatesTbl.getExpectedTotalCost() < another.nodeStatesTbl.getExpectedTotalCost()) {
					return -1;
				} else if (this.nodeStatesTbl.getExpectedTotalCost() == another.nodeStatesTbl.getExpectedTotalCost()) {
					return 0;
				} else {
					return 1;
				}
			}
		}
		

}
