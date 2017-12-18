#! /bin/bash
# May 10, 2017 by JSo

#set -x

if [ $# -ne 7 ]; then
    echo "USAGE: ${0} USERNAME DIRNAME REPO1 REPO2 DESTREPO PROJECT HOSTNAME:PORT"
    echo "Error --> Need 7 ARGS: Git Username, Output Dir (under ${HOME}),"
    echo "                       Repo1 Name, Repo2 Name, Destnation Repo Name,"
    echo "                       Stash Project Name and Server:Port"
    echo
    exit 1
fi 

# Configure some vars
USERNAME=${1}
DIR=${2}
TGT=${HOME}/${DIR}

# These are the names of 2 repos in stash that you want to merge into one
R1=${3}
R2=${4}

# This is the name of the target repo in stash you want to merge the above into
R=${5}

# This is the project name in stash
P=${6}

# Name of stash server (server:port)
HOSTNAME="${7}"

# We output into $HOME so we need to check if it exists
if [ ! -d ${HOME} ]; then
    echo "Error --> ${HOME} does not exist"
    exit 1
fi

# Make target (if needed) and hop right on in
if [ ! -d ${TGT} ]; then
    mkdir -p ${TGT}
fi
cd ${TGT}

# Clone down the repos as USERNAME
git clone https://${USERNAME}@${HOSTNAME}/scm/${P}/${R}.git
git clone https://${USERNAME}@${HOSTNAME}/scm/${P}/${R1}.git
git clone https://${USERNAME}@${HOSTNAME}/scm/${P}/${R2}.git

# CD into R1
cd ${R1}
# Get list of all remote branches in this repo
R1B=$(git branch --all | grep '^\s*remotes' | egrep --invert-match '(:?HEAD|master)$' | cut -d/ -f2-)
for branch in ${R1B}; do
    # Was `git branch --track "${branch##*/}" "$branch"`, but only gave last name
    # Trimming 'origin' off the branch name
    bs=$(echo ${branch} | cut -d/ -f2-)
    # Set up a tracking branch for each remote branch in R1
    git branch --track "${bs}" "$branch"
done

# CD into R2
cd ../${R2}
# Get list of all remote branches in this repo
R2B=$(git branch --all | grep '^\s*remotes' | egrep --invert-match '(:?HEAD|master)$' | cut -d/ -f2-)
for branch in ${R2B}; do
    # Trimming 'origin' off the branch name
    bs=$(echo ${branch} | cut -d/ -f2-)
    # Set up a tracking branch for each remote branch in R2
    git branch --track "${bs}" "$branch"
done

# Move content into subfolder in the R2 repo
# We can skip this on the R1 repo since we want the cookbooks at bottom level
mkdir -p ${R2}
git mv -k * ${R2}
git commit -m "--> Merging ${R1} and ${R2} repositories..."

# CD to the new merge repo and add the two remotes as local filesystems
cd ../${R}
git remote add -f ${R1} ${TGT}/${R1}
git remote add -f ${R2} ${TGT}/${R2}

# Pull in the master branch from each repo allowing unrelated histories
git pull ${R1} master
git pull --allow-unrelated-histories ${R2} master

# Verify
git log --oneline --graph --decorate --all

# Grab the branches from R1 repo and merge
for branch in ${R1B}; do
    echo "--> Processing ${branch} from ${R1}"
    echo
    bs=$(echo ${branch} | cut -d/ -f2-)
    echo ${branch} | grep -q feature
    if [ $? -eq 0 ]; then
        parent="bit-develop"
    else
        parent="master"
    fi
    echo "--> ${branch}'s parent is ${parent}"
    # Need the commit that the branch diverged from master as
    commit=$(cd ../${R1} && git log ${parent}..${branch} --oneline | tail -1 | awk '{print $1}')
    if [ ! -z ${commit} ]; then
        # Since commit is not empty then branch from it, check it out & pull in remote tracking
        git branch ${bs} ${commit}
        git checkout ${bs}
        echo "--> Pulling in branch ${branch} from ${R1}"
        git pull ${R1} ${branch}
    else
        # Since commit is empty we assume its already been merged to parent
        echo "--> Resultant commit was empty"
        git branch ${bs}
        git checkout ${bs}
        echo "--> Pulling in branch ${branch} from ${R1}"
        git pull ${R1} ${branch}
    fi
    git status | grep "On branch" | awk '{print $3}' | grep master
    if [ $? -eq 1 ]; then
        git checkout master
    fi
    echo
done

# Grab the branches from R2 repo and merge as necessary
for branch in ${R2B}; do
    echo "--> Processing ${branch} from ${R2}"
    bs=$(echo ${branch} | cut -d/ -f2-)
    echo ${branch} | grep -q feature
    if [ $? -eq 0 ]; then
        parent="bit-develop"
    else
        parent="master"
    fi
    echo "--> ${branch}'s parent is ${parent}"
    # Need the id of the commit from which the branch diverged from its parent
    commit=$(cd ../${R2} && git log ${parent}..${branch} --oneline | tail -1 | awk '{print $1}')
    if [ ! -z ${commit} ]; then
        # Test if the branch exists in the R1 repo already
        echo "${R1B}" | grep -qi ${bs}
        if [ $? -eq 1 ]; then
            # Nope, new branch so create it
            git branch ${bs} ${commit}
            if [ $? -eq 0 ]; then
                # Checkout the branch and pull in the repo allowing unrelated histories
                echo "--> Pulling in branch ${branch} from ${R2}"
                git checkout ${bs}
                git pull ${R2} ${bs}
                mkdir -p ${R2}
                files=$(find . -type f -maxdepth 1)
                for f in ${files}; do
                    git mv -k ${f} ${R2}
                done
                git commit -m "--> Moving contents into ${R2} subdirectory for branch ${bs}..."
                git pull --allow-unrelated-histories ${R2} ${branch}
                if [ $? -ne 0 ]; then
                    exit 1
                fi
            else
                # Error can't create branch for some reason
                echo "Error --> Couldn't create branch ${bs} in ${R}"
            fi
        else
            # Yep, branch already exists, check it out and lets try to merge 'em
            git checkout ${bs}
            out=${?}
            git pull --allow-unrelated-histories ${R2} ${bs}
            mkdir -p ${R2}
            files=$(find . -name 'Berksfile' -prune -o -type f -maxdepth 1 -print)
            for f in ${files}; do
                git mv -k ${f} ${R2}
            done
            git commit -m "--> Moving contents into ${R2} subdirectory for branch ${bs}..."
            if [ ${out} -eq 0 ]; then
                # Pull in the unrelated history
                echo "--> Pulling in branch ${branch} from ${R2}"
                git pull --allow-unrelated-histories ${R2} ${branch}
                if [ $? -ne 0 ]; then
                    exit 1
                fi
            else
                echo "Error --> Couldn't checkout branch ${bs} in ${R}"
            fi
        fi
    else
        # We get here if the branch was already fully merged to its parent
        echo "--> Resultant commit was empty"
        # Test if the branch exists in the R1 repo already
        echo "${R1B}" | grep -qi ${bs}
        if [ $? -eq 1 ]; then
            # Nope, new branch so create it
            git branch ${bs}
            if [ $? -eq 0 ]; then
                # Checkout the branch and pull in the repo allowing unrelated histories
                echo "--> Pulling in branch ${branch} from ${R2}"
                git checkout ${bs}
                git pull ${R2} ${bs}
                mkdir -p ${R2}
                files=$(find . -type f -maxdepth 1)
                for f in ${files}; do
                    git mv -k ${f} ${R2}
                done
                git commit -m "--> Moving contents into ${R2} subdirectory for branch ${bs}..."
                git pull --allow-unrelated-histories ${R2} ${branch}
                if [ $? -ne 0 ]; then
                    exit 1
                fi
            else
                # Error can't create branch for some reason
                echo "Error --> Couldn't create branch ${bs} in ${R}"
            fi
        else
            # Yep, branch already exists, check it out and lets try to merge 'em
            git checkout ${bs}
            out=${?}
            git pull --allow-unrelated-histories ${R2} ${bs}
            mkdir -p ${R2}
            files=$(find . -name 'Berksfile' -prune -o -type f -maxdepth 1 -print)
            for f in ${files}; do
                git mv -k ${f} ${R2}
            done
            git commit -m "--> Moving contents into ${R2} subdirectory for branch ${bs}..."
            if [ ${out} -eq 0 ]; then
                # Pull in the unrelated history
                echo "--> Pulling in branch ${branch} from ${R2}"
                git pull --allow-unrelated-histories ${R2} ${branch}
                if [ $? -ne 0 ]; then
                    exit 1
                fi
            else
                echo "Error --> Couldn't checkout branch ${bs} in ${R}"
            fi
        fi
    fi
    git status | grep "On branch" | awk '{print $3}' | grep master
    if [ $? -eq 1 ]; then
        git checkout master
    fi
    echo
done

# Verify again
git log --oneline --graph --decorate --all

echo "--> You can rerun 'git log --oneline --graph --decorate --all' from inside $TGT/${R} to verify again..." 
echo

exit 0
