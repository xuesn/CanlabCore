% function [B, Bb, Bw, pc_b, sc_b, pc_w, sc_w] = mlpcr2(X,Y,varargin)
%
% Multilevel PCR v2.0 designed for prediction on datasets with multiple 
% subjects and multiple observations per subject. This function is most
% conveniently invoked using fmri_data/predict with the cv_mlpcr,
% cv_mlpcr_bt or cv_mlpcr_wi 'algorithm_name' arguments.
%
% Identifies within block (subject) eigenvectors with optional balancing 
% across subjects. Computes loadings of full dataset on these within 
% subject eigenvectors (so they can vary both within and between blocks). 
% Comptes a separate PCA on the residual and obtains a second set of 
% orthogonal components and scores which only vary between blocks. Performs 
% regression of between and within loadings (jointly) on pain outcome, and 
% projects regression coefficients back to voxel space using within and 
% between eigenvectors.
%
% regression is OLS (default) or moore-penrose pseudoinverse (rank
% deficient data), not some mixed effects thing. Within subject PCA is 
% rate limiting step.
%
% If the defaults are used then the result is identical to PCR, only you 
% get both within and between subject predictive models in addition to the 
% full model.
%
% Input ::
%
%   X           - n x p data matrix
%
%   Y           - n x 1 outcome vector
%
%   'subjIDs    - n x 1 vector (ideal) or cellstr (throws warning, but
%                   fine) indicating group affilitations.
%
% Optional Input ::
%
%   'numcomponents'
%               - 1 x 2 numeric vector indicating number of PCA dimensions
%                   to retain at the between and within levels
%                   (respectively). Use Inf to autoselect based on
%                   available degrees of freedom. default: [Inf, Inf]
%                 Note 1: bayesopt from the Statistics and Machine Leraning
%                   matlab toolbox provides an elegant way to optimize
%                   these variables.
%                 Note 2: More dimensions result in less biased solutions,
%                   which is a good reason for using the default choice.
%
%   'cpca'      - followed by 0/1 to indicate whether or not concensus PCA
%                   (Westerhuis, et al. 1998) should be used in place of 
%                   standard pca. If concensus PCA is enabled eigenvectors 
%                   will be selected such that variance is explained 
%                   equally across all blocks. Otherwise eigenvectors will 
%                   best represent blocks with the most observations.
%                 Note 1: for optimization of dimension hyperparameters
%                   specify a custom loss function that also balances the 
%                   weight of each block. fmri_data/predict won't do this
%                   and will consequently fight against CPCA. A future 
%                   update may fix this, and if so this note should be 
%                   removed.
%                 Note 2: In principle concensus PCA could be implemened
%                   for traditional PCR too. It just hasn't been.
%
% Output ::
%
%   B           - B(1) is intercept, B(2:end) are regression weights in X 
%                   space.
%
%   Bb          - Bb(1) is intercept. Bb(2:end) are regression weights of
%                   between block variance components in X space.
%
%   Bw          - Bw(1) is zero. Bb(2:end) are regression weights of within
%                   block variance components in X space.
%
%   pc_b        - between eigenvectors
%
%   sc_b        - scores on between eigenvectors
%
%   pc_w        - within eigenvectors
%
%   sc_w        - scores on within eigenvectors
%
%
% Version History ::
%
%   MLPCR was originally developed using mixed effects models (version 1,
%   Petre, et al., 2019), however model fitting was prohibitively slow and
%   consequently was never fully evaluated for performance. Version 2.0
%   substitutes (optionally weighted) OLS for much faster convergence, and
%   minimaly different weight fitting. Version 1 is much more flexible than
%   version 2, and is still available in CanlabPrivate for potential future
%   development. It has been removed from CanlabCore.
%
% References ::
%
%   Pete B, Woo W, Losin E, Eisenbarth H, Wager TD. (2019) Separate within
%       -subject and individual-difference predictions with multilevel
%       MVPA. Society for Neuroscience, San Diego, CA. (included with 
%       canlabCore mlpcr library in pdf).
%
%   Westerhuis J, Kourti T, MacGregor J. (1998) Analysis of Multiblock and 
%       Hierarchical PCA and PLS Methods. Journal of Chemometrics 12(5).
%   
%
% Designed and writen by Bogdan, 5/4/2020
%                   
%
%
% ToDo:
% - Enable between or within dimension retention priority for bootstrapping
%   (allowing the user to force retention of one or the other even if
%   eigenvalue rank doesn't justify it)
% - passthrough options to higher level cv_mlpcr, cv_mlpcr_bt and
%   cv_mlpcr_wi scripts. Concensus PCA should also use concensus cv_err,
%   cv_mlpcr_wi and cv_mlpcr_bt should have within and between priority
%   (respectively) by default.

function [B, Bb, Bw, pc_b, sc_b, pc_w, sc_w] = mlpcr(X,Y,varargin)
    subjIDs = [];
    wiDim = Inf;
    btDim = Inf;
    cpca = 0;
    for i = 1:length(varargin)
        if ischar(varargin{i})
            switch varargin{i}
                case 'subjIDs'
                    subjIDs = varargin{i+1}(:);
                case 'numcomponents'
                    nc = varargin{i+1};
                    btDim = nc(1);
                    wiDim = nc(2);
                case 'cpca'
                    cpca = varargin{i+1};
            end
        end
    end
    
    if isempty(subjIDs)
        error('Cannot perform multilevel PCR without a subjIDs identifier');
    end
    
    [~, grp_exemplar, subjIDs] = unique(subjIDs,'rows','stable');
    uniq_grp = unique(subjIDs);
    
    % get centering and expansion matrices
    n_grp = length(uniq_grp);
    cmat = [];
    emat = [];
    sf = []; % scale factor for imbalanced datasets
    for i = 1:n_grp
        this_grp = uniq_grp(i);
        this_n = sum(this_grp == subjIDs);
        cmat = blkdiag(cmat, eye(this_n) - 1/this_n);
        emat = blkdiag(emat,ones(this_n,1));
        sf = [sf(:); 1/sqrt(this_n)*ones(this_n,1)];
    end
    if ~cpca
        sf = ones(size(sf));
    end
    
    % compute preliminary within fractions
    Xw = cmat*X;
    
    if wiDim > 0
        % determine within dimension retention
        if wiDim > length(subjIDs) - length(uniq_grp)
            if wiDim < Inf % something user supplied was too big
                warning('Max wiDim exceeds max df, reseting wiDim to %d',length(subjIDs) - length(uniq_grp) - 1);
            end

            wiDim = length(subjIDs) - length(uniq_grp);
        end
        
        
        % Get concensus PCA solution, which weighs each block equally
        % requires Matlab 2016b or later perform operation across all
        %   columns like this with sf
        [pc_w,~,~] = svd((sf.*Xw)', 'econ');
        pc_w = pc_w(:,1:wiDim);                
        
        sc_w = X*pc_w;
        
        % note: sc_w*pc_w' ~= Xw, it pulls scores from the entire dataset,
        % 	Some of the between fraction may vary along the within
        % 	components, and we want to pull that into the within scores.
        % 	sc_w*pc_w' is not necessarily mean zero within subject.
        
        % modified Xb, invariant with subject, but not exactly the subject
        %   ean either due to the missing variance along pc_w
        Xr = X - sc_w*pc_w';
        Xb = Xr - cmat*Xr; % if we don't have full wiDim then there's residual within variance to remove
        Xb = Xb(grp_exemplar,:);
    else
        [pc_w, sc_w] = deal([]);
        
        Xb = X - Xw;
        Xb = Xb(grp_exemplar,:);
    end
    
    if btDim > 0
        % get between components from residual between fraction
        if btDim > length(uniq_grp) - 1
            if btDim < Inf % something user supplied was too big
                warning('Max btDim exceeds max df, reseting btDim to %d',length(uniq_grp) - 1);
            end

            btDim = length(uniq_grp) - 1;
        end
        
        [pc_b,~,~] = svd(scale(Xb,1)','econ');
        pc_b = pc_b(:,1:btDim);
        sc_b = Xb*pc_b;
    else
        [pc_b, sc_b] = deal([]);
    end
    
    if ~isempty(sc_b) 
        sc_b = emat*sc_b; 
        bDim = 1:size(sc_b,2);
        wDim = (1:size(sc_w,2)) + bDim(end);
    else
        bDim = [];
        wDim = 1:size(sc_w,2);
    end
    sc = [sc_b, sc_w];
    pc = [pc_b, pc_w];
    
    
    % 3/8/13 TW solution from cv_pcr code to use numcomps, because sc is 
    %   not always full rank during bootstrapping. 
    % Modified by Bogdan for use in mlpcr to keep componens with the 
    %   highest ranking eigenvectors (not necessarily sequential in mlpcr 
    %   because of within/between stratification)
    % ToDo: create a bootstrap priority option to allow the user to specify
    %   whether they want to prefer between or within component retention
    %   regardless of eigenvalue size.
    if rank(sc) == size(sc,2)
        numcomps = rank(sc); 
        retainComps = 1:numcomps;
        
        bDim(~ismember(bDim,retainComps)) = [];
        wDim(~ismember(wDim,retainComps)) = [];
    elseif rank(sc) < size(sc,2)
        numcomps = rank(sc)-1;
        [~,compRank] = sort(var(sc),'descend');
        retainComps = compRank(1:numcomps);
        
        bDim(~ismember(bDim,retainComps)) = [];
        wDim(~ismember(wDim,retainComps)) = [];
        
        sc_w = sc_w(:,wDim);
        sc_b = sc_b(:,bDim);
        pc_w = pc_w(:,wDim);
        pc_b = pc_b(:,bDim);
        
        if ~any(ismember(bDim,retainComps)), warning('All between dimensions dropped due to rank deficiency'); end
        if ~any(ismember(wDim,retainComps)), warning('All within dimensions dropped due to rank deficiency'); end
    end
    
    xx = [ones(size(Y, 1), 1) sc(:, retainComps)];
    
    if rank(xx) <= size(sc, 2)
        % compute (optional: weighted) pseudoinverse if not full rank
        [u,s,v] = svd(sf.^2.*xx,'econ');
        s = diag(s);
        s(s~=0) = 1./s(s~=0);
        s = diag(s);
        pinv_xx = v*s*u';
        
        b = pinv_xx * Y;
    else
        b = inv(xx'*diag(sf.^2)*xx)*xx'*diag(sf.^2)*Y;
    end
    
    if ~isempty(retainComps)
        B = [b(1); pc(:,retainComps)*b(2:end)];
    else
        B = b;
    end
    
    if isempty(bDim)
        Bb = [b(1); zeros(size(X,2),1)];
    else
        Bb = [b(1); pc(:,bDim)*b(bDim + 1)];
    end
    
    if isempty(wDim)
        Bw = [0; zeros(size(X,2),1)];
    else
        Bw = [0; pc(:,wDim)*b(wDim + 1)];
    end
end