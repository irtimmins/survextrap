
functions {

    vector mspline_log_haz(vector alpha, matrix basis, matrix coefs) {
        return log(rows_dot_product(basis, coefs)) + alpha;
    }

    vector mspline_log_surv(vector alpha, matrix ibasis, matrix coefs) {
        vector[rows(alpha)] res;
        res = - (rows_dot_product(ibasis, coefs)) .* exp(alpha);
        if (exp(res[1]) > 1) {
            reject("Probability > 1 computed. Not your fault - report a bug to the developer.");
        }
        return res;
    }

    vector mspline_log_dens(vector alpha, matrix basis, matrix ibasis, matrix coefs) {
        vector[rows(alpha)] res;
        /* haz = dens / surv , loghaz = logdens - logsurv , logdens = loghaz + logsurv  */
        res = mspline_log_haz(alpha, basis, coefs)  +
        mspline_log_surv(alpha, ibasis, coefs);
        return res;
    }

    vector log_surv(vector alpha, matrix ibasis, matrix coefs,
		    data int cure, vector pcure,
		    data int modelid) {
        vector[rows(alpha)] res;
        vector[rows(alpha)] base_logsurv;
	base_logsurv = mspline_log_surv(alpha, ibasis, coefs);
        if (cure) {
            for (i in 1:rows(alpha)) {
                res[i] = log(pcure[i] + (1 - pcure[i])*exp(base_logsurv[i]));
            }
        } else {
            res = base_logsurv;
        }
        return res;
    }

    vector log_haz(vector alpha, matrix basis, matrix coefs,
		   data int cure, vector pcure, matrix ibasis,
		   data int modelid, data int relative,
		   vector backhaz) {
        vector[rows(alpha)] res;
        vector[rows(alpha)] base_logdens;
        vector[rows(alpha)] base_loghaz;
        vector[rows(alpha)] logsurv;
        if (cure) {
	    base_logdens = mspline_log_dens(alpha, basis, ibasis, coefs);
            logsurv = log_surv(alpha, ibasis, coefs, cure, pcure, modelid); // includes cure 
            for (i in 1:rows(alpha)){
                res[i] = log(1 - pcure[i]) + base_logdens[i] - logsurv[i];
            }
        } else {
	    base_loghaz = mspline_log_haz(alpha, basis, coefs);
            res = base_loghaz;
        }
	if (relative) {
	    for (i in 1:rows(alpha)){
		res[i] = log(backhaz[i] + exp(res[i]));
	    }
	}
        return res;
    }

    vector log_dens(vector alpha, matrix basis, matrix coefs,
		    data int cure, vector pcure, matrix ibasis,
		    data int modelid,
		    data int relative, vector backhaz){
        vector[rows(alpha)] res;
        res = log_haz(alpha, basis, coefs, cure, pcure, ibasis, modelid, relative, backhaz) +
	    log_surv(alpha, ibasis, coefs, cure, pcure, modelid);
        return res;
    }

    /**
    * Log-prior for intercept parameters
    *
    * @param gamma Real, the intercept parameter
    * @param dist Integer, the type of prior distribution
    * @param location Real, location of prior distribution
    * @param scale Real, scale for the prior distribution
    * @param df Real, df for the prior distribution
    * @return Nothing
    */
    real loghaz_lp(real gamma, int dist, real location, real scale, real df) {
        if (dist == 1)  // normal
        target += normal_lpdf(gamma | location, scale);
        else if (dist == 2)  // student_t
        target += student_t_lpdf(gamma | df, location, scale);
        /* else dist is 0 and nothing is added */
        return target();
    }

    real loghr_lp(vector loghr, int[] dist, vector location, vector scale, vector df) {
	for (i in 1:rows(loghr)){
	    if (dist[i] == 1)  // normal
		target += normal_lpdf(loghr[i] | location[i], scale[i]);
	    else if (dist[i] == 2)  // student_t
		target += student_t_lpdf(loghr[i] | df[i], location[i], scale[i]);
	}
        /* else dist is 0 and nothing is added */
        return target();
    }

}

data {
    int<lower=0> nevent;     // num. rows w/ an event (ie. not censored)
    int<lower=0> nrcens;     // num. rows w/ right censoring
    int<lower=0> nvars;      // num. aux parameters for baseline hazard
    int<lower=0> nextern;    // number of time points with external data
    int<lower=0> ncovs;      // number of covariate effects on the hazard
    int<lower=0> ncurecovs;      // number of covariate effects on the cure probability

    // basis matrices for M-splines / I-splines, without quadrature
    matrix[nevent,nvars] basis_event;  // at event time
    matrix[nevent,nvars] ibasis_event; // at event time
    matrix[nrcens,nvars] ibasis_rcens; // at right censoring time
    matrix[nextern,nvars] ibasis_ext_stop;  // at times with external data
    matrix[nextern,nvars] ibasis_ext_start; //
    matrix[nevent,ncovs] x_event; // matrix of covariate values
    matrix[nrcens,ncovs] x_rcens;
    matrix[nevent,ncurecovs] xcure_event; // matrix of covariate values on cure prob
    matrix[nrcens,ncurecovs] xcure_rcens;

    // external data describing knowledge about long-term survival
    // expressed as binomial outcomes of r survivors by t2 out of n people alive at t1
    int<lower=0> r_ext[nextern];
    int<lower=0> n_ext[nextern];
    matrix[nextern,ncovs] x_ext;
    matrix[nextern,ncurecovs] xcure_ext;

    vector[nvars-1] b_mean; // logit of prior guess at basis weights (by default, those that give a constant hazard)
    int est_hsd;
    vector<lower=0>[1-est_hsd] hsd_fixed;

    int cure;

    int relative; 
    vector[nevent] backhaz_event; 
    vector[nextern] backsurv_ext_start; 
    vector[nextern] backsurv_ext_stop; 

    int prior_hscale_dist;
    vector[3] prior_hscale;
    vector<lower=0>[2] prior_cure;
    vector<lower=0>[2*est_hsd] prior_hsd;
    int<lower=0> prior_loghr_dist[ncovs];
    vector[ncovs] prior_loghr_location;
    vector[ncovs] prior_loghr_scale;
    vector[ncovs] prior_loghr_df;
    int<lower=0> prior_logor_cure_dist[ncurecovs];
    vector[ncurecovs] prior_logor_cure_location;
    vector[ncurecovs] prior_logor_cure_scale;
    vector[ncurecovs] prior_logor_cure_df;

    int modelid;
    int nonprop;

    // EXTRA FOR NONPROP HAZ MODEL 
    matrix[ncovs*nonprop,2] prior_hrsd;
}

parameters {
    real gamma[1];
    vector[ncovs] loghr;
    vector[nvars-1] b_err;
    vector<lower=0>[est_hsd] hsd;
    vector<lower=0,upper=1>[cure] pcure;
    vector[ncurecovs] logor_cure;

    // STUFF FOR NON PROP HAZ MODEL 
    vector<lower=0>[ncovs*nonprop] hrsd;  // NP shrinkage SD for each cov
    matrix[ncovs*nonprop,nvars-1] nperr;  // standard normal for departure from PH
}

transformed parameters {
    vector[nvars] b;
    vector[nvars] coefs; // with covariates = zero 

    matrix[nevent,nvars] coefs_event; // was coefs vector[nvars]
    matrix[nrcens,nvars] coefs_rcens;
    matrix[nextern,nvars] coefs_extern;

    // nonprop only, but declare outside {} so values are saved
    matrix[nevent,nvars] b_event; // was vector[nvars]
    matrix[nrcens,nvars] b_rcens; 
    matrix[nextern,nvars] b_extern; 
    matrix[ncovs,nvars-1] b_np; // nonproportionality cov effect. should be centred around 0. no intercept
    real ssd;

    if ((ncovs>0) && nonprop) { 
	for (r in 1:ncovs){
	    b_np[r,1:(nvars-1)] = hrsd[r]*nperr[r,1:(nvars-1)];
	}
	if (est_hsd) {
	    ssd = hsd[1];
	} else {
	    ssd = hsd_fixed[1];
	}
	b = append_row(0, b_mean + b_err*ssd);
	coefs = softmax(b);
	if (nevent > 0) {
	    b_event[1:nevent,1] = rep_vector(0,nevent);
	    for (j in 1:(nvars-1)) {
		b_event[1:nevent,j+1] = b_mean[j] + x_event*b_np[,j] + b_err[j]*ssd;
	    }
	    for (i in 1:nevent){
		coefs_event[i,1:nvars] = to_row_vector(softmax(to_vector(b_event[i,1:nvars])));
	    }
	}
	if (nrcens > 0) {
	    b_rcens[1:nrcens,1] = rep_vector(0,nrcens);
	    for (j in 1:(nvars-1)) {
		b_rcens[1:nrcens,j+1] = b_mean[j] + x_rcens*b_np[,j] + b_err[j]*ssd;
	    }
	    for (i in 1:nrcens){
		coefs_rcens[i,1:nvars] = to_row_vector(softmax(to_vector(b_rcens[i,1:nvars])));
	    }
	}
	if (nextern > 0) {
	    b_extern[1:nextern,1] = rep_vector(0,nextern);
	    for (j in 1:(nvars-1)) {
		b_extern[1:nextern,j+1] = b_mean[j] + x_ext*b_np[,j] + b_err[j]*ssd;
	    }
	    for (i in 1:nextern){
		coefs_extern[i,1:nvars] = to_row_vector(softmax(to_vector(b_extern[i,1:nvars])));
	    }
	}
    } else {
	if (est_hsd)
	    b = append_row(0, b_mean + b_err*hsd[1]);
	else
	    b = append_row(0, b_mean + b_err*hsd_fixed[1]);
	coefs = softmax(b);
	if (nevent > 0) {
	    for (i in 1:nevent){
		coefs_event[i,1:nvars] = to_row_vector(coefs);
	    }
	}
	if (nrcens > 0) {
	    for (i in 1:nrcens){
		coefs_rcens[i,1:nvars] = to_row_vector(coefs);
	    }
	}
	if (nextern > 0) {
	    for (i in 1:nextern){
		coefs_extern[i,1:nvars] = to_row_vector(coefs);
	    }
	}
	// these values are unused in the PH model but they still need to be defined
	for (j in 1:nvars) {
	    if (nevent>0) { b_event[1:nevent,j] = rep_vector(0,nevent); }
	    if (nrcens>0) { b_rcens[1:nrcens,j] = rep_vector(0,nrcens); }
	    if (nextern>0) { b_extern[1:nextern,j] = rep_vector(0,nextern); }
	}
	for (j in 1:(nvars-1)){
	    if (ncovs>0) { b_np[1:ncovs,j] = rep_vector(0,ncovs); }
	}
	ssd = 0;
    }
}

model {
    vector[nevent] alpha_event; // for events
    vector[nrcens] alpha_rcens; // for right censored
    vector[nextern] alpha_extern; // for external data
    real dummy;
    real cp;
    vector[nextern] p_ext_stop; // unconditional survival prob at external time points
    vector[nextern] p_ext_start; //
    vector[nevent] pcure_event; //
    vector[nrcens] pcure_rcens; //
    vector[nextern] pcure_extern; //

    if (nevent > 0) alpha_event = rep_vector(prior_hscale[1] + gamma[1], nevent);
    if (nrcens > 0) alpha_rcens = rep_vector(prior_hscale[1] + gamma[1], nrcens);
    if (nextern > 0) alpha_extern = rep_vector(prior_hscale[1] + gamma[1], nextern);

    if (ncovs > 0) {
        // does x * beta,    matrix[n,K] * vector[K], matrix product
        if (nevent > 0) alpha_event += x_event * loghr;
        if (nrcens > 0) alpha_rcens += x_rcens * loghr;
        if (nextern > 0) alpha_extern += x_ext * loghr;
    } 

    if (cure) cp = pcure[1]; else cp = 0;
    pcure_event = rep_vector(cp, nevent);
    pcure_rcens = rep_vector(cp, nrcens);
    pcure_extern = rep_vector(cp, nextern);

    if (ncurecovs > 0){
        if (nevent > 0) pcure_event = inv_logit(logit(pcure_event) + xcure_event * logor_cure);
        if (nrcens > 0) pcure_rcens = inv_logit(logit(pcure_rcens) + xcure_rcens * logor_cure);
        if (nextern > 0) pcure_extern = inv_logit(logit(pcure_extern) + xcure_ext * logor_cure);
    }

    if (nevent > 0) target +=  log_dens(alpha_event,  basis_event, coefs_event, cure, pcure_event,
					ibasis_event, modelid, relative, backhaz_event);
    if (nrcens > 0) target +=  log_surv(alpha_rcens, ibasis_rcens, coefs_rcens, cure, pcure_rcens,
					modelid);

    if (nextern > 0) {
        p_ext_stop = exp(log_surv(alpha_extern, ibasis_ext_stop, coefs_extern, cure, pcure_extern,
				  modelid)) .* backsurv_ext_stop;
        p_ext_start = exp(log_surv(alpha_extern, ibasis_ext_start, coefs_extern, cure, pcure_extern,
				   modelid)) .* backsurv_ext_start;
        target += binomial_lpmf(r_ext | n_ext, p_ext_stop ./ p_ext_start);
    }

    // log prior for baseline log hazard
    dummy = loghaz_lp(gamma[1], prior_hscale_dist, 0, 
		      prior_hscale[2], prior_hscale[3]);

    // log prior for covariates on the log hazard
    dummy = loghr_lp(loghr, prior_loghr_dist, prior_loghr_location,
        		     prior_loghr_scale, prior_loghr_df);

    // prior for spline coefficient random effect term
    b_err ~ logistic(0, 1);

    // prior for cure fraction
    if (cure) {
        pcure ~ beta(prior_cure[1], prior_cure[2]);
    }
    if (ncurecovs > 0){
	// log prior for covariates on the log odds of cure
	dummy = loghr_lp(logor_cure, prior_logor_cure_dist, prior_logor_cure_location,
			 prior_logor_cure_scale, prior_logor_cure_df);
    }
    
    if (est_hsd){
        hsd ~ gamma(prior_hsd[1], prior_hsd[2]);
    }

    // Non-proportional haz model
    if ((ncovs > 0) && nonprop) { 
	hrsd ~ gamma(prior_hrsd[,1], prior_hrsd[,2]);
	for (i in 1:ncovs){
	    nperr[i,1:(nvars-1)] ~ std_normal();
	}
    }
}

generated quantities {
    real alpha = prior_hscale[1] + gamma[1]; // log hazard, intercept, log(eta) in the docs
    vector[ncovs] hr = exp(loghr);
    vector[ncurecovs] or_cure = exp(logor_cure);
}
