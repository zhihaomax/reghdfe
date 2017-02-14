// Common functions ---------------------------------------------------------
mata:

// --------------------------------------------------------------------------
// BUGBUG: not sure if this is still used...
// --------------------------------------------------------------------------
`StringRowVector' clean_tokens(`String' vars)
{
	`StringRowVector' 		ans
	`Integer'				i
	ans = tokens(vars)
	for (i=1; i<=cols(ans); i++) {
		ans[i] = invtokens(tokens(ans[i]))
	}
	return(ans)
}


// --------------------------------------------------------------------------
// Each col of A will have stdev of 1 unless stdev is quite close to 0
// --------------------------------------------------------------------------
`RowVector' function reghdfe_standardize(`Matrix' A)
{
	`RowVector'				stdevs
	`Integer'				i, K

	assert(!isfleeting(A))
	K = cols(A)
	stdevs = J(1, K, .)
	for (i=1; i<=K; i++) {
		stdevs[i] = sqrt(quadvariance(A[., i]))
	}
	// stdevs = editvalue(stdevs, 0, 1)
	//stdevs = colmax(( stdevs \ J(1, K, sqrt(epsilon(1))) ))
	stdevs = colmax(( stdevs \ J(1, K, 1e-3) ))
	A = A :/ stdevs
	return(stdevs)
}


// --------------------------------------------------------------------------
// Divide two row vectors but adjust the denominator if it's too small
// --------------------------------------------------------------------------
`RowVector' safe_divide(`RowVector' numerator, `RowVector' denominator, | `Real' epsi) {
	 // If the denominator goes below machine precision, the division explodes
	 if (args()<3 | epsi==.) epsi = epsilon(1)
	return( numerator :/ colmax(denominator \ J(1,cols(denominator),epsi)) )
}


// If X is not square...
// `Matrix' R
// real colvector tau, p

// _hqrdp(A, tau, R, p=.)
// B = hqrdmultq1t(A, tau, B)
// rank = _solveupper(R, B, tol)
// B = B[invorder(p),.]
// +- +-

// invsym(makesymmetric(..))





// --------------------------------------------------------------------------
// Robust solver for Ax=b
// --------------------------------------------------------------------------
// Mata utility for sequential use of solvers
// Default is cholesky;
// if that fails, use QR;
// if overridden, use QR.
// Author: Schaffer, Mark E <M.E.Schaffer@hw.ac.uk>
// --------------------------------------------------------------------------
// Warning:
// cholqrsolve calls qrsolve which calls _qrsolve which calls ...
// Does all the indirection makes it too slow to use within a panel?
// --------------------------------------------------------------------------
`Matrix' function reghdfe_cholqrsolve(`Matrix' A,
                                      `Matrix' B,
                                    | `Boolean' useqr)
{
	`Matrix' C
	if (args()<3 | useqr==.) useqr = 0
	
	if (!useqr) {
		C = cholsolve(A, B)
		if (hasmissing(C)) useqr = 1
	}

	if (useqr) {
		C = qrsolve(A, B)
	}

	return(C)
}


// --------------------------------------------------------------------------
// OLS Regression
// --------------------------------------------------------------------------
`Void' function reghdfe_post_ols(`FixedEffects' S,
                                 `Variable' y,
                                 `Variables' X,
                                 `String' bname,
                                 `String' Vname,
                                 `String' nname,
                                 `String' rname,
                                 `String' dfrname)
{
	`Integer'				N
	`Integer'				rank
	`Integer'				df_r
	`Vector'				b
	`Matrix'				V
	`Variable'				resid
	`Real'					eps
	`Integer'				i

	reghdfe_solve_ols(S, y, X, b=., V=., N=., rank=., df_r=., resid=.)
	st_matrix(bname, b')
	eps = sqrt(epsilon(1))
	for (i=1; i<=rows(b); i++) {
		if (abs(b[i])<eps) printf("{txt}(note: %s omitted because of collinearity)\n", tokens(S.options.indepvars)[i])
	}
	st_matrix(Vname, V)
	st_numscalar(nname, N)
	st_numscalar(rname, rank)
	st_numscalar(dfrname, df_r)

	if (S.options.residuals != "") {
		if (S.verbose > 0) printf("\n{txt} ## Storing residuals in the dataset variable %s\n\n", S.options.residuals)
		S.save_variable(S.options.residuals, resid, "Residuals")
	}
}


`Void' function reghdfe_solve_ols(`FixedEffects' S,
                                  `Variable' y,
                                  `Variables' X,
                                  `Vector' b,
                                  `Matrix' V,
                                  `Integer' N,
                                  `Integer' rank,
                                  `Integer' df_r,
                                  `Vector' resid)
{
	`Integer'				K
	`Matrix'				xx, inv_xx, W, inv_V
	`Vector' 				xy, w
	`Integer'				used_df_r

	if (S.options.vcetype == "unadjusted" & S.weighttype=="pweight") S.options.vcetype = "robust"
	if (S.verbose > 0) printf("\n{txt} ## Solving least-squares regression of partialled-out variables\n\n")

	// Weight FAQ:
	// - fweight: obs. i represents w[i] duplicate obs. (there is no loss of info wrt to having the "full" dataset)
	// - aweight: obs. i represents w[i] distinct obs. that were mean-collapsed (so there is loss of info and hetero)
	//	 soln: normalize them so they sum to N (the true number of obs in our sample), and then treat them as fweight
	// - pweight: each obs. represents only one obs. from the pop, that was drawn from w[i] individuals
	//	          we want to make inference on the population, so if we interviewed 100% of the men and only 10% of women,
	//            then without weighting we would be over-representing men, which leads to a loss of efficiency +-+-
	// 			  it is the same as aweight + robust
	// We need to pick N and w
	N = rows(y) // Default; will change with fweights
	w = 1
	if (S.weighttype=="fweight") {
		N = sum(S.weight)
		w = S.weight
	}
	else if (S.weighttype=="aweight" | S.weighttype=="pweight") {
		w = S.weight * (N / sum(S.weight))
	}

	// Build core matrices
	xx = quadcross(X, w, X)
	xy = quadcross(X, w, y)
	S.output.tss_within = quadcross(y, w, y)
	b = reghdfe_cholqrsolve(xx, xy, 1) // qr or chol?
	resid = y - X * b
	S.output.rss = quadcross(resid, w, resid) // do before reghdfe_robust() modifies w

	// Bread of the robust VCV matrix
	inv_xx = reghdfe_rmcoll(tokens(S.options.indepvars), xx) // invsym(xx, 1..K)
	S.output.df_m = rank = cols(X) - diag0cnt(inv_xx)
	K = rank + S.output.df_a
	S.output.df_r = N - K // replaced when clustering

	// Compute full VCE
	assert_msg(anyof( ("unadjusted", "robust", "cluster") , S.options.vcetype), S.options.vcetype)
	if (S.options.vcetype == "unadjusted") {
		if (S.verbose > 0) {
			printf("{txt}    - Small-sample-adjustment: q = N / (N-df_m-df_a) = %g / (%g - %g - %g) = %g\n", N, N, rank, S.output.df_a, N / (N-K) )
		}
		V = quadcross(resid, w, resid) / (N - K)  * inv_xx
	}
	else if (S.options.vcetype == "robust") {
		V = reghdfe_robust(S, X, inv_xx, resid, w, N, K)
	}
	else {
		V = reghdfe_cluster(S, X, inv_xx, resid, w, N, K)
	}

	// Wald test: joint significance
	inv_V = invsym(V) // this might not be of full rank but numerical inaccuracies hide it
	if (diag0cnt(inv_V)) {
		if (S.verbose > -1) printf("{txt}(Warning: missing F statistic; dropped variables due to collinearity or too few clusters)\n")
		W = .
	}
	else {
		W = b' * inv_V * b / S.output.df_m
		if (missing(W) & S.verbose > -1) printf("{txt}(Warning: missing F statistic)\n")
	}

	// V can be missing if b is completely absorbed by the FEs
	if (missing(V)) {
		if (S.verbose > 0) printf("{txt}    - VCE has missing values, setting it to zeroes (are your regressors all collinear?)\n")
		V = J(rows(V), rows(V), 0)
	}

	// Results
	S.output.title = "Linear regression"
	S.output.model = "ols"
	
	if (S.weighttype!="") S.output.sumweights = quadsum(S.weight)

	used_df_r = N - K - S.output.M_due_to_nested
	S.output.r2 = 1 - S.output.rss / S.output.tss
	S.output.r2_a = 1 - (S.output.rss / used_df_r) / (S.output.tss / (N - S.has_intercept ) )
	S.output.r2_within = 1 - S.output.rss / S.output.tss_within
	S.output.r2_a_within = 1 - (S.output.rss / used_df_r) / (S.output.tss_within / (used_df_r + rank))

	S.output.ll = - 0.5 * N * (1 + ln(2 * pi()) + ln(S.output.rss / N))
	S.output.ll_0 = - 0.5 * N * (1 + ln(2 * pi()) + ln(S.output.tss_within / N))

	S.output.rmse = sqrt(S.output.rss / used_df_r)
	if (used_df_r==0) S.output.rmse = sqrt(S.output.rss)
	S.output.F = W
	df_r = S.output.df_r // reghdfe_cluster might have updated it
}


// --------------------------------------------------------------------------
// Robust VCE
// --------------------------------------------------------------------------
// Advice: Delegate complicated regressions to -avar- and specialized routines
// BUGBUG: do we standardize X again? so V is well behaved?
// Notes:
// - robust is the same as cluster robust where cluster==_n
// - cluster just "collapses" X_i * e_i for each group, and builds M from that

`Matrix' reghdfe_robust(`FixedEffects' S,
                        `Variables' X,
						`Matrix' D,
						`Variable' resid,
						`Variable' w,
						`Integer' N,
						`Integer' K)
{
	`Matrix'				M, V
	`Integer'				dof_adj

	if (S.verbose > 0) printf("\n{txt} ## Estimating Robust Variance-Covariance Matrix of the Estimators (VCE)\n\n")
	if (S.verbose > 0) printf("{txt}    - VCE type: {res}%s{txt}\n", S.options.vcetype)
	if (S.verbose > 0) printf("{txt}    - Weight type: {res}%s{txt}\n", S.weighttype=="" ? "<none>" : S.weighttype)

	if (S.weighttype=="") {
		w = resid :^ 2
	}
	else if (S.weighttype=="fweight") {
		w = resid :^ 2 :* w
	}
	else if (S.weighttype=="aweight" | S.weighttype=="pweight") {
		w = (resid :* w) :^ 2
	}

	dof_adj = N / (N - K)
	M = quadcross(X, w, X)
	if (S.verbose > 0) {
		printf("{txt}    - Small-sample-adjustment: q = N / (N-df_m-df_a) = %g / (%g - %g - %g) = %g\n", N, N, K-S.output.df_a, S.output.df_a, N / (N-K) )
	}
	V = D * M * D * dof_adj
	return(V)
}

`Matrix' reghdfe_cluster(`FixedEffects' S,
                        `Variables' X,
						`Matrix' D,
						`Variable' resid,
						`Variable' w,
						`Integer' N,
						`Integer' K)
{
	`Matrix' 				M, V
	`Integer'				dof_adj, N_clust, df_r, nested_adj
	`Integer'				Q, q, g, sign, i, j
	pointer(`Factor') rowvector FPlist
	`FactorPointer'			FP
	`Varlist'				vars
	`String'				var, var_with_spaces
	`Boolean'				clustervar_is_absvar, required_fix
	`Matrix'				tuples
	`RowVector'				tuple
	`RowVector'				N_clust_list
	`Matrix'				joined_levels

	w = resid :* w
	//if (S.weighttype=="") {
	//	w = resid
	//}
	//else if (S.weighttype=="fweight") {
	//	w = resid :* w
	//}
	//else if (S.weighttype=="aweight" | S.weighttype=="pweight") {
	//	w = resid :* w
	//}

	vars = S.options.clustervars
	Q = cols(vars)
	if (S.verbose > 0) printf("\n{txt} ## Estimating Cluster Robust Variance-Covariance Matrix of the Estimators (VCE)\n\n")
	if (S.verbose > 0) printf("{txt}    - VCE type: {res}%s{txt} (%g-way clustering)\n", S.options.vcetype, Q)
	if (S.verbose > 0) printf("{txt}    - Cluster variables: {res}%s{txt}\n", invtokens(vars))
	if (S.verbose > 0) printf("{txt}    - Weight type: {res}%s{txt}\n", S.weighttype=="" ? "<none>" : S.weighttype)
	assert_msg(0 < Q & Q < 10)

	// Get or build factors associated with the clustervars
	FPlist = J(1, Q, NULL)
	N_clust_list = J(1, Q, .)
	for (q=1; q<=Q; q++) {
		var = vars[q]
		clustervar_is_absvar = 0
		for (g=1; g<=S.G; g++) {
			if (invtokens(S.factors[g].varlist, "#") == var) {
				clustervar_is_absvar = 1
				FP = &(S.factors[g])
				break
			}
		}
		var_with_spaces = subinstr(var, "#", " ")
		if (!clustervar_is_absvar) FP = &(factor(var_with_spaces, S.sample, ., "", ., ., ., 0))
		N_clust_list[q] = (*FP).num_levels
		if (S.verbose > 0) printf("{txt}    - {res}%s{txt} has {res}%g{txt} levels\n", var, N_clust_list[q])
		FPlist[q] = FP
	}

	// Build the meat part of the V matrix
	if (S.verbose > 0) printf("{txt}    - Computing the 'meat' of the VCE\n")
	M = J(cols(X), cols(X), 0)
	tuples = .
	for (q=1; q<=Q; q++) {
		tuples = reghdfe_choose_n_k(Q, q, tuples)
		sign = mod(q, 2) ? 1 : -1 // + with odd number of variables, - with even
		for (j=1; j<=rows(tuples); j++) {
			tuple = tuples[j, .]
			if (S.verbose > 0) printf("{txt}      - Level %g/%g; sublevel %g/%g; M = M %s ClusterVCE(%s)\n", q, Q, j, rows(tuples), sign > 0 ? "+" : "-" , invtokens(strofreal(tuple)))
			if (q==1) {
				assert(tuple==j)
				FP =  FPlist[j]
			}
			else if (q==2) {
				FP = &join_factors( *FPlist[tuple[1]] , *FPlist[tuple[2]] , ., ., 1)
			}
			else {
				joined_levels = (*FPlist[tuple[1]]).levels
				for (i=2; i<=cols(tuple); i++) {
					joined_levels = joined_levels, (*FPlist[tuple[i]]).levels
				}
				FP = &_factor(joined_levels, ., ., "", ., ., ., 0)
			}
			M = M + sign * reghdfe_vce_cluster_meat(FP, X, w)
		}
	}

	// Build VCE
	N_clust = min(N_clust_list)
	nested_adj = (S.output.df_a==0) // minor adj. so we match xtreg when the absvar is nested within cluster
	// (when ..nested.., df_a is zero so we divide N-1 by something that can potentially be N (!))
	// so we either add the 1 back, or change the numerator (and the N_clust-1 factor!)
	dof_adj = (N - 1) / (N - nested_adj - K) * N_clust / (N_clust - 1) // adjust for more than 1 cluster
	if (S.verbose > 0) {
		printf("{txt}    - Small-sample-adjustment: q = (%g - 1) / (%g - %g) * %g / (%g - 1) = %g\n", N, N, K+nested_adj, N_clust, N_clust, dof_adj)
	}
	V = D * M * D * dof_adj
	if (Q > 1) {
		required_fix = reghdfe_fix_psd(V)
		if (required_fix) printf("{txt}Warning: VCV matrix was non-positive semi-definite; adjustment from Cameron, Gelbach & Miller applied.\n")
	}

	// Store e()
	assert(!missing(S.output.df_r))
	df_r = N_clust - 1
	if (S.output.df_r > df_r) {
		S.output.df_r = df_r
	}
	else if (S.verbose > 0) {
		printf("{txt}    - Unclustered df_r (N - df_m - df_a = %g) are {it:lower} than clustered df_r (N_clust-1 = %g)\n", S.output.df_r, df_r)
		printf("{txt}      Thus, we set e(df_r) as the former.\n")
		printf("{txt}      This breaks consistency with areg but ensures internal consistency\n")
		printf("{txt}      between vce(robust) and vce(cluster _n)\n")
	}
	
	S.output.N_clust = N_clust
	S.output.N_clust_list = N_clust_list

	return(V)
}


`Matrix' reghdfe_vce_cluster_meat(`FactorPointer' FP,
                                  `Variables' X,
                                  `Variable' resid)
{
	`Integer'				i, N_clust
	`Variables'				X_sorted
	`Variable'				resid_sorted
	`Matrix'				X_tmp
	`Vector'				resid_tmp
	`RowVector'				Xe_tmp
	`Matrix'				M

	N_clust = (*FP).num_levels
	(*FP).panelsetup()
	X_sorted = (*FP).sort(X)
	resid_sorted = (*FP).sort(resid)
	M = J(cols(X), cols(X), 0)

	for (i=1; i<=N_clust; i++) {
		X_tmp = panelsubmatrix(X_sorted, i, (*FP).info)
		resid_tmp = panelsubmatrix(resid_sorted, i, (*FP).info)
		Xe_tmp = quadcross(1, resid_tmp, X_tmp) // Faster than colsum(e_tmp :* X_tmp)
		M = M + quadcross(Xe_tmp, Xe_tmp)
	}

	return(M)
}


// Enumerate all combinations of K integers from N integers
// Kroneker approach based on njc's tuples.ado
`Matrix' reghdfe_choose_n_k(`Integer' n, `Integer' k, `Matrix' prev_ans)
{
	`RowVector' v
	`Integer' q
	`Matrix' candidate
	`Matrix' ans
	v = 1::n
	if (k==1) return(v)

	q = rows(prev_ans)
	assert(q==comb(n, k-1))
	assert(cols(prev_ans)==k-1)
	candidate = v # J(q, 1, 1)
	candidate = candidate , J(n, 1, prev_ans)	
	ans = select(candidate, candidate[., 1] :< candidate[., 2])
	return(ans)
}


// --------------------------------------------------------------------------
// Fix non-positive VCV
// --------------------------------------------------------------------------
// If the VCV matrix is not positive-semidefinite, use the fix from
// Cameron, Gelbach & Miller - Robust Inference with Multi-way Clustering (JBES 2011)
// 1) Use eigendecomposition V = U Lambda U' where U are the eigenvectors and Lambda = diag(eigenvalues)
// 2) Replace negative eigenvalues into zero and obtain FixedLambda
// 3) Recover FixedV = U * FixedLambda * U'
`Boolean' function reghdfe_fix_psd(`Matrix' V) {
	`Matrix'				U
	`Matrix'				lambda
	`Boolean' 				required_fix

	if (!issymmetric(V)) _makesymmetric(V)
	if (!issymmetric(V)) exit(error(505))
	symeigensystem(V, U=., lambda=.)
	if (min(lambda)<0) {
		lambda = lambda :* (lambda :>= 0)
		// V = U * diag(lambda) * U'
		V = quadcross(U', lambda, U')
		required_fix = 1
	}
	else {
		required_fix = 0
	}
	return(required_fix)
}


// --------------------------------------------------------------------------
// Remove collinear variables
// --------------------------------------------------------------------------
// Based on ivreg2's s_rmcoll2
`Matrix' reghdfe_rmcoll(`Varlist' varnames,
                      `Matrix' xx)
{
	`Integer'				K
	`Matrix'				inv_xx, smat
	`RowVector'				vl_drop, vl_keep

	assert(rows(xx)==cols(xx))
	K = cols(xx)
	inv_xx = K ? invsym(xx, 1..K) : J(0, 0, .)
	st_numscalar("r(k_omitted)", diag0cnt(inv_xx))
	smat = (diagonal(inv_xx) :== 0)'
	vl_drop = select(varnames, smat)
	vl_keep = select(varnames, !smat)
	if (cols(vl_keep)) st_global("r(varlist)", invtokens(vl_keep))
	if (cols(vl_drop)) st_global("r(omitted)", invtokens(vl_drop))
	return(inv_xx)
}

end



