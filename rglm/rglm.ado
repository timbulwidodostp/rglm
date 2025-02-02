/*
  Fit a generalized linear model with Huber or semi-Huber variances.
  (Semi-Huber variances are robust
  to conditional variance mis-specification,
  caused by overdispersion, underdispersion,
  heteroscedasticity and clustering,
  whereas full Huber variances are also robust
  to mis-specification of conditional means with noncanonical links.)
  This program was converted by Roger Newson in 1997-1998
  from an original named hglm, kindly provided by David Clayton,
  which gave semi-Huber variances,
  assuming true specification of conditional means.
*/

program define rglm
    version 5.0
    local options "LEvel(integer $S_level) EForm"

    /*
      Call __rglm if necessary, after first executing glm if necessary
    */
    if "`1'"!="" & substr("`1'",1,1)!="," {
        /* There is a varlist --- run glm */
	local options "`options' Cluster(string) MSpec"
        local options "`options' TDist minus(int -1) *"
	local varlist "req ex"
	local in "opt"
	local if "opt"
	local weight "fweight aweight iweight"
	parse "`*'"
        if("`cluster'"!="") {
            local cluster="cluster(`cluster')"
        }
        quietly glm `varlist' `if' `in' [`weight'`exp'], /*
            */ level(`level') `eform' `options'
	__rglm, `cluster' `mspec' `tdist' minus(`minus')
    }
    else if "$S_E_cmd"=="glm" {
        /* glm has been run --- just calculate Huber standard errors */
	local options "`options' Cluster(string) MSpec"
        local options "`options' TDist minus(int -1)"
        parse "`*'"
        if("`cluster'"!="") {
            local cluster="cluster(`cluster')"
        }
        __rglm, `cluster' `mspec' `tdist' minus(`minus')
    }
    else if "$S_E_cmd"=="rglm" {
        /* Redisplay existing rglm fit */
	local options "`options' Cluster(string) MSpec"
        local options "`options' TDist minus(int -1)"
        parse "`*'"
        if(("`cluster'"!="")|("`mspec'"!="") /*
            */ |("`tdist'"!="")|("`minus'"!="")) {
            disp in green "Note: cluster, mspec, tdist and minus" /*
                */ " ignored when re-displaying existing fit"
        }
    }
    else{
        /* Exit because last command was not glm or rglm */
        di in red "Last command was not glm or rglm"
        exit
    }

    /* Display results */
    if("$S_E_mspe"=="mspec"){
        di in gr "GLM with full Huber standard errors"
    }
    else{
        di in gr "GLM with semi-Huber standard errors"
    }
    di in gr "$S_E_flo"
    if("$S_E_cvn"!=""){
	di in gr  "Clustering variable: " in ye "$S_E_cvn"
        di in gr  "Number of clusters: " in ye "$S_E_cn"
    }
    di in gr "Number of observations: " in ye "$S_E_nobs"
    if("$S_E_wgt"!=""){
        di in gr "Weights: " in ye "$S_E_wgt $S_E_exp"
    }
    if "`eform'"!="" {local eform "eform(e^coef)"}
    matrix mlout, level(`level') `eform'

end

/*
  This program calculates Huber standard errors after glm has been run
*/

capture program drop __rglm
program define __rglm
    version 5.0
    local options "Cluster(string) MSpec TDist minus(int -1)"
    parse "`*'"
    tempvar mu eta vf dvf dm d2m resid ys yi fwt awt rwt touse
    tempname coefs VCE
    local weight "$S_E_wgt"
    local exp "$S_E_exp"
    local family "$S_E_fam"
    local link "$S_E_link"
    local if "$S_E_if"
    local in "$S_E_in"
    local flo "$S_E_flo"
    local pow "$S_E_pow"
    local bden "$S_E_m"
    local ber "$S_E_ber"
    local nbk "$S_E_k"
    local nobs "$S_E_nobs"
    local rdf "$S_E_rdf"
    local depv "$S_E_depv"
    local vl "$S_E_vl"
    local offs "$S_E_off"
    local dev "$S_E_dev"
    local chi2 "$S_E_chi2"
    local small 1e-6

    /*
      If minus is negative (as by default) then set to the default value
      (equal to the number of parameters in the current model)
    */
    if(`minus'<0){
        local minus=`nobs'-`rdf'
    }

    /*
      Extract parameter estimates
    */
    matr `coefs'=get(_b)

    /*
      Create parameter count in nparm,
      and set noconst to "noconst" if no constant, "" otherwise
    */
    local parmlst : colnames(`coefs')
    local nparm: word count of `parmlst'
    local noconst="noconst"
    local i1=0
    while(`i1'<`nparm'){
      local i1=`i1'+1
      local parm : word `i1' of `parmlst'
      if("`parm'"=="_cons"){
        local noconst=""
      }
    }

    /*
      Assign macros yv and xv
      containing y-variate and list of x-variates
    */
    parse "$S_E_vl", parse(" ")
    local yv "`1'"
    mac shift
    local xv "`*'"
    /*
      Generate predicted means, eta-values and residuals
    */
    qui glmpred double `mu', mu
    qui glmpred double `eta', xb
    qui gen double `resid'=`mu'-`yv'
    /*
      Create xb as linear predictor (minus offset if present),
      to be regressed on x-variates
      to produce pre-Huber information matrix
    */
    if "`offs'"=="" {
	local xb "`eta'"
    }
    else {
	tempvar xb
	gen double `xb' = `eta' - `offs'
    }

    /* Create marking variable named in macro touse */
    mark `touse' [`weight'`exp'] `if' `in'
    markout `touse' `varlist' `cluster',strok

    /* Create macro grs containing clustering option */
    if ("`cluster'"!="") {
        local grs "cluster(`cluster')"
    }

    /*
      Generate frequency and nonfrequency weights in all circumstances
      (frequency weights are entered as such,
      nonfrequency weights are used to scale scores and information)
    */
    if "`weight'"!="" {
	if ("`weight'"=="fweight") {
	    qui gen `fwt'`exp'
	    qui gen `awt'=1
	}
	else {
            qui gen `fwt'=1
	    qui gen `awt'`exp'
	}
    }
    else {
        qui gen `fwt'=1
	qui gen `awt'=1
    }

    /*
      If there is a binomial denominator,
      then divide fitted y-values and residuals by it
      and multiply nonfrequency weights by it
      (so variance and inverse link functions and their derivatives
      can be defined more simply in terms of Bernoulli probability
      instead of in terms of binomial mean)
    */
    if("`bden'"!=""){
        qui replace `mu'=`mu'/`bden'
        qui replace `resid'=`resid'/`bden'
        qui replace `awt'=`awt'*`bden'
    }

    /*
      Variance functions and their first derivatives
    */
    if "`family'"=="gau" {
	qui gen double `vf' = 1
        qui gen double `dvf' = 0
    }
    else if "`family'"=="gam" {
	qui gen double `vf' = `mu'^2
        qui gen double `dvf' = 2*`mu'
    }
    else if "`family'"=="ivg" {
	qui gen double `vf' = `mu'^3
        qui gen double `dvf' = 3*`mu'^2
    }
    else if "`family'"=="nb" {
	qui gen double `vf' = `mu' + `nbk'*(`mu'^2)
        qui gen double `dvf' = 1 + 2*`nbk'*`mu'
    }
    else if "`family'"=="bin" {
	qui gen double `vf' = `mu'*(1-`mu')
        qui gen double `dvf' = 1 - 2*`mu'
    }
    else if "`family'"=="poi" {
	qui gen double `vf' = `mu'
        qui gen double `dvf' = 1
    }
    else {
	di in re "Unrecognized family of distributions"
	exit
    }

    /*
      First and second derivatives of inverse link functions.
      (Code is partially cribbed from glm
      and uses the fact that, in the case of canonical link functions,
      the first derivative of the inverse link function
      is proportional to the variance function,
      and the second derivative of the inverse link function
      is similarly proportional
      to the first derivative of the variance function
      multiplied by the first derivative of the inverse link function)
    */

    if "`link'"=="pow"{
        /*
          This covers identity and log links
          for `pow' equal to 1 and 0, respectively
        */
        if abs(`pow')<`small' {
            quietly gen double `dm'=`mu'
            quietly gen double `d2m'=`mu'
        }
        else{
            quietly gen double `dm'=1/(`pow'*`mu'^(`pow'-1))
            quietly gen double `d2m'=`dm'*(1-`pow')/(`pow'*`mu'^`pow')
        }
    }
    else if "`link'"=="l" {
        quietly gen double `dm'=`mu'*(1-`mu')
        quietly gen double `d2m'=`dm'*(1-2*`mu')
    }
    else if "`link'"=="p" {
        quietly gen double `dm'=exp(-0.5*`eta'*`eta')/sqrt(2*_pi)
        quietly gen double `d2m'=-`eta'*`dm'
    }
    else if "`link'"=="c" {
        tempvar q logq
        quietly gen double `q'=1-`mu'
        quietly gen double `logq'=ln(`q')
        quietly gen double `dm'=-`q'*`logq'
        quietly gen double `d2m'=`dm'*(1+`logq')
        quietly drop `q' `logq'
    }
    else if "`link'"=="opo" {
        tempvar q oddsp
        quietly gen double `q'=1-`mu'
        quietly gen double `oddsp'=(`q'/`mu')^`pow'
        quietly gen double `dm'=`oddsp'*`mu'*`q'
        quietly gen double `d2m'=`dm'*`oddsp'*(`q'-`mu'-`pow')
        quietly drop `q' `oddsp'
    }
    /*
      If link not given, use canonical link for distributional family
      (using the fact that the first derivative
      of the inverse canonical link
      is proportional to the variance function,
      and the second derivative of the inverse canonical link
      is similarly proportional
      to the derivative of the variance function
      multiplied by the first derivative of the inverse canonical link)
    */
    else if "`family'"=="gam"{
        quietly gen double `dm'=-`vf'
        quietly gen double `d2m'=-`dvf'*`dm'
    }
    else if "`family'"=="ivg"{
        quietly gen double `dm'=-0.5*`vf'
        quietly gen double `d2m'=-0.5*`dvf'*`dm'
    }
    else if("`family'"=="nb")|("`fam'"=="poi"){
        quietly gen double `dm'=`vf'
        quietly gene double `d2m'=`dvf'*`dm'
    }
    else {
        di in red "Unrecognized link"
	exit
    }


    /* Score and Information contributions */
    qui gen double `ys' = `dm'*`resid'/`vf'
    qui gen double `yi' = `dm'*`dm'
    /*
      Misspecification correction can be missed out
      if we only want semi-Huber variance
    */
    if("`mspec'"!=""){
        qui replace `yi'=`yi' + `d2m'*`resid' - `dm'*`dvf'*`ys'
    }
    qui replace `yi'=`yi'/`vf'
    /*
      Weight score and information contributions
      with nonfrequency weights
    */
    qui replace `ys'=`awt'*`ys'
    qui replace `yi'=`awt'*`yi'
    /*
      Create pre-Huber information matrix in VCE
      and use _robust to do Huber transformation
    */
    qui gene double `rwt'=`fwt'*`yi'
    qui regress `xb' `xv' if `touse' [iweight=`rwt'] , `noconst' mse1
    mat `VCE'=get(VCE)
    qui _robust `ys' [fweight=`fwt'] if `touse' , /*
       */ variance(`VCE') `grs' minus(`minus')
    /*
      Set local macros to be copied to global macros before exit
    */
    local cn=_result(3)
    local mdf=`nobs'-`rdf'
    local rdf=`cn'-`mdf'
    if("`mspec'"!=""){
      local vcehea "Huber"
    }
    else{
      local vcehea "Semi-Huber"
    }
    /*
       Post coefficients and variance-covariance matrix
    */
    if("`tdist'"!=""){
      matr post `coefs' `VCE', obs(`nobs') dep(`depv') dof(`rdf')
    }
    else{
      matr post `coefs' `VCE', obs(`nobs') dep(`depv')
    }

    /* Set global macros before exit */
    global S_E_mspe "`mspec'"
    global S_E_tdis "`tdist'"
    global S_E_minu="`minus'"
    global S_E_vce "`vcehea'"
    global S_E_cvn "`cluster'"
    global S_E_cn "`cn'"
    global S_E_wgt "`weight'"
    global S_E_exp "`exp'"
    global S_E_fam "`family'"
    global S_E_link "`link'"
    global S_E_if "`if'"
    global S_E_in "`in'"
    global S_E_flo "`flo'"
    global S_E_pow "`pow'"
    global S_E_m "`bden'"
    global S_E_ber "`ber'"
    global S_E_k "`nbk'"
    global S_E_nobs "`nobs'"
    global S_E_mdf "`mdf'"
    global S_E_rdf "`rdf'"
    global S_E_depv "`depv'"
    global S_E_vl "`vl'"
    global S_E_off "`offs'"
    global S_E_dev "`dev'"
    global S_E_chi2 "`chi2'"
    global S_E_cmd "rglm"

end
