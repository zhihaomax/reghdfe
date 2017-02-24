mata:

// --------------------------------------------------------------------------
// Acceleration Schemes
// --------------------------------------------------------------------------

`Variables' function accelerate_test(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	`Integer'	iter, g
	`Variables'		resid
	`Factor' f
	pragma unset resid

	for (iter=1; iter<=S.maxiter; iter++) {
		for (g=1; g<=S.G; g++) {
			f = S.factors[g]
			if (g==1) resid = y - panelmean(f.sort(y), f)[f.levels, .]
			else resid = resid - panelmean(f.sort(resid), f)[f.levels, .]
		}
		if (check_convergence(S, iter, resid, y)) break
		y = resid
	}
	return(resid)
}

// --------------------------------------------------------------------------

`Variables' function accelerate_none(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	`Integer'	iter
	`Variables'		resid
	pragma unset resid

	for (iter=1; iter<=S.maxiter; iter++) {
		(*T)(S, y, resid) // Faster version of "resid = S.T(y)"
		if (check_convergence(S, iter, resid, y)) break
		y = resid
	}
	return(resid)
}
// --------------------------------------------------------------------------

// Start w/out acceleration, then switch to CG
`Variables' function accelerate_hybrid(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	`Integer' iter, accel_start
	`Variables' resid
	pragma unset resid

	accel_start = 6

	for (iter=1; iter<=accel_start; iter++) {
		(*T)(S, y, resid) // Faster version of "resid = S.T(y)"
		if (check_convergence(S, iter, resid, y)) break
		y = resid
	}

	T = &transform_sym_kaczmarz() // Override

	return(accelerate_cg(S, y, T))
}

// --------------------------------------------------------------------------
// Memory cost is approx = 4*size(y) (actually 3 since y is already there)
// But we need to add maybe 1 more due to u:*v
// And I also need to check how much does project and T use..
// Double check with a call to memory

// For discussion on the stopping criteria, see the following presentation:
// Arioli & Gratton, "Least-squares problems, normal equations, and stopping criteria for the conjugate gradient method". URL: https://www.stfc.ac.uk/SCD/resources/talks/Arioli-NAday2008.pdf

// Basically, we will use the Hestenes and Stiefel rule

`Variables' function accelerate_cg(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	// BUGBUG iterate the first 6? without acceleration??
	`Integer'	iter, d, Q
	`Variables'		r, u, v
	`RowVector' alpha, beta, ssr, ssr_old, improvement_potential
	`Matrix' recent_ssr
	pragma unset r
	pragma unset v

	Q = cols(y)
	
	d = 1 // BUGBUG Set it to 2/3 // Number of recent SSR values to use for convergence criteria (lower=faster & riskier)
	// A discussion on the stopping criteria used is described in
	// http://scicomp.stackexchange.com/questions/582/stopping-criteria-for-iterative-linear-solvers-applied-to-nearly-singular-system/585#585

	improvement_potential = weighted_quadcolsum(S, y, y)
	recent_ssr = J(d, Q, .)
	
	(*T)(S, y, r, 1)
	ssr = weighted_quadcolsum(S, r, r) // cross(r,r) when cols(y)==1 // BUGBUG maybe diag(quadcross()) is faster?
	u = r

	for (iter=1; iter<=S.maxiter; iter++) {
		(*T)(S, u, v, 1) // This is the hottest loop in the entire program
		alpha = safe_divide( ssr , weighted_quadcolsum(S, u, v) )
		recent_ssr[1 + mod(iter-1, d), .] = alpha :* ssr
		improvement_potential = improvement_potential - alpha :* ssr
		y = y - alpha :* u
		r = r - alpha :* v
		ssr_old = ssr
		ssr = weighted_quadcolsum(S, r, r)
		beta = safe_divide( ssr , ssr_old) // Fletcher-Reeves formula, but it shouldn't matter in our problem
		u = r + beta :* u
		// Convergence if sum(recent_ssr) > tol^2 * improvement_potential
		if ( check_convergence(S, iter, colsum(recent_ssr), improvement_potential, "hestenes") ) break
	}
	return(y)
}

// --------------------------------------------------------------------------

`Variables' function accelerate_sd(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	`Integer'	iter, g
	`Variables' proj
	`RowVector' t
	pragma unset proj

	for (iter=1; iter<=S.maxiter; iter++) {
		(*T)(S, y, proj, 1)
		if (check_convergence(S, iter, y-proj, y)) break
		t = safe_divide( weighted_quadcolsum(S, y, proj) , weighted_quadcolsum(S, proj, proj) )
		if (uniform(1,1)<0.1) t = 1 // BUGBUG: Does this REALLY help to randomly unstuck an iteration?

		y = y - t :* proj
		
		if (S.storing_alphas) {
			for (g=1; g<=S.G; g++) {
				//g, ., ., t
				//asarray(S.factors[g].extra, "alphas"), asarray(S.factors[g].extra, "tmp_alphas")
				if (S.save_fe[g]) {
					asarray(S.factors[g].extra, "alphas",
					    asarray(S.factors[g].extra, "alphas") +
					    t :* asarray(S.factors[g].extra, "tmp_alphas")
					)
				}
			}
		}
	}
	return(y-proj)
}

// --------------------------------------------------------------------------
// This is method 3 of Macleod (1986), a vector generalization of the Aitken-Steffensen method
// Also: "when numerically computing the sequence.. stop..  when rounding errors become too 
// important in the denominator, where the ^2 operation may cancel too many significant digits"
// Note: Sometimes the iteration gets "stuck"; can we unstuck it with adding randomness
// in the accelerate decision? There should be a better way.. (maybe symmetric kacz instead of standard one?)

`Variables' function accelerate_aitken(`FixedEffects' S, `Variables' y, `FunctionP' T) {
	`Integer'	iter
	`Variables'		resid, y_old, delta_sq
	`Boolean'	accelerate
	`RowVector' t
	pragma unset resid

	y_old = J(rows(y), cols(y), .)

	for (iter=1; iter<=S.maxiter; iter++) {
		
		(*T)(S, y, resid)
		accelerate = iter>=S.accel_start & !mod(iter,S.accel_freq)

		// Accelerate
		if (accelerate) {
			delta_sq = resid - 2 * y + y_old // = (resid - y) - (y - y_old) // Equivalent to D2.resid
			// t is just (d'd2) / (d2'd2)
			t = safe_divide( weighted_quadcolsum(S,  (resid - y) , delta_sq) ,  weighted_quadcolsum(S, delta_sq , delta_sq) )
			resid = resid - t :*  (resid - y)
		}

		// Only check converge on non-accelerated iterations
		// BUGBUG: Do we need to disable the check when accelerating?
		// if (check_convergence(S, iter, accelerate? resid :* .  : resid, y)) break
		if (check_convergence(S, iter, resid, y)) break
		y_old = y // y_old is resid[iter-2]
		y = resid // y is resid[iter-1]
	}
	return(resid)
}

// --------------------------------------------------------------------------

`Boolean' check_convergence(`FixedEffects' S, `Integer' iter, `Variables' y_new, `Variables' y_old,| `String' method) {
	`Boolean'	is_last_iter
	`Real'		update_error

	// max() ensures that the result when bunching vars is at least as good as when not bunching
	if (args()<5) method = "vectors" 

	if (S.G==1 & !S.storing_alphas) {
		// Shortcut for trivial case (1 FE)
		update_error = 0
	}
	else if (method=="vectors") {
		update_error = max(mean(reldif(y_new, y_old), S.weight))
	}
	else if (method=="hestenes") {
		// If the regressor is perfectly explained by the absvars, we can have SSR very close to zero but negative
		// (so sqrt is missing)
		// todo: add weights to hestenes (S.weight , as in vectors)
		update_error = max(safe_divide( sqrt(y_new) , editmissing(sqrt(y_old), sqrt(epsilon(1)) ) , sqrt(epsilon(1)) ))
	}
	else {
		exit(error(100))
	}

	assert_msg(!missing(update_error), "update error is missing")

	S.converged = (update_error <= S.tolerance)
	is_last_iter = iter==S.maxiter
	
	if (S.converged) {
		S.iteration_count = iter
		if (S.verbose==1) printf("{txt}    converged in %g iterations (last error =%3.1e)\n", iter, update_error)
		if (S.verbose>1) printf("\n{txt}    - Converged in %g iterations (last error =%3.1e)\n", iter, update_error)
	}
	else if (is_last_iter & S.abort) {
		printf("\n{err}convergence not achieved in %g iterations (last error=%e); try increasing maxiter() or decreasing tol().\n", S.maxiter, update_error)
		exit(430)
	}
	else {
		if ((S.verbose>=2 & S.verbose<=3 & mod(iter,1)==0) | (S.verbose==1 & mod(iter,1)==0)) {
			printf("{res}.{txt}")
			displayflush()
		}
		if ( (S.verbose>=2 & S.verbose<=3 & mod(iter,100)==0) | (S.verbose==1 & mod(iter,100)==0) ) {
			printf("{txt}%9.1f\n      ", update_error/S.tolerance)
		}

		if (S.verbose==4 & method!="hestenes") printf("{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e\n", iter, update_error)
		if (S.verbose==4 & method=="hestenes") printf("{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e  {txt}norm(ssr)={res}%g\n", iter, update_error, norm(y_new))
		
		if (S.verbose==5) {
			printf("\n{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e{txt}\tmethod={res}%s\n", iter, update_error, method)
			"old:"
			y_old
			"new:"
			y_new
		}
	}
	return(S.converged)
}

// --------------------------------------------------------------------------

`Matrix' weighted_quadcolsum(`FixedEffects' S, `Matrix' x, `Matrix' y) {
	// BUGBUG: colsum or quadcolsum??
	// BUGBUG: override S.has_weights with pruning
	return( quadcolsum(S.has_weights ? (x :* y :* S.weight) : (x :* y) ) )
}
end