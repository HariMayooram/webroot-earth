#!/bin/bash

# git.sh - Streamlined git operations for webroot repository
# Usage: ./git.sh [command] [options]

set -e  # Exit on any error

# Helper function to check if we're in webroot
check_webroot() {
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$CURRENT_REMOTE" != *"webroot"* ]]; then
        echo "⚠️ ERROR: Not in webroot repository."
        exit 1
    fi
}

# Add upstream remote if it doesn't exist
add_upstream() {
    local repo_name="$1"
    local is_capital="$2"
    
    if [ -z "$(git remote | grep upstream)" ]; then
        if [[ "$is_capital" == "true" ]]; then
            git remote add upstream "https://github.com/ModelEarth/$repo_name.git"
        else
            git remote add upstream "https://github.com/modelearth/$repo_name.git"
        fi
    fi
}

# Merge from upstream with fallback branches
merge_upstream() {
    local repo_name="$1"
    git fetch upstream 2>/dev/null || git fetch upstream
    
    # Try main/master first for all repos
    if git merge upstream/main --no-edit 2>/dev/null; then
        return 0
    elif git merge upstream/master --no-edit 2>/dev/null; then
        return 0
    # Only try dev branch for useeio.js
    elif [[ "$repo_name" == "useeio.js" ]] && git merge upstream/dev --no-edit 2>/dev/null; then
        return 0
    else
        echo "⚠️ Merge conflicts - manual resolution needed"
        return 1
    fi
}

# Detect parent repository account (modelearth or partnertools)
get_parent_account() {
    local repo_name="$1"
    
    # Check if upstream remote exists and points to expected parent
    local upstream_url=$(git remote get-url upstream 2>/dev/null || echo "")
    if [[ "$upstream_url" == *"modelearth/$repo_name"* ]]; then
        echo "modelearth"
    elif [[ "$upstream_url" == *"partnertools/$repo_name"* ]]; then
        echo "partnertools"
    else
        # Fallback: try to determine from typical parent structure
        if [[ "$repo_name" == "localsite" ]] || [[ "$repo_name" == "home" ]] || [[ "$repo_name" == "webroot" ]]; then
            echo "ModelEarth"  # Capital M for these repos
        else
            echo "modelearth"  # lowercase for others
        fi
    fi
}

# Create fork and update remote to user's fork
setup_fork() {
    local name="$1"
    local parent_account="$2"
    
    echo "🍴 Creating fork of $parent_account/$name..."
    
    # Create fork (gh handles case where fork already exists)
    local fork_url=$(gh repo fork "$parent_account/$name" --clone=false 2>/dev/null || echo "")
    
    if [ -n "$fork_url" ]; then
        echo "✅ Fork created/found: $fork_url"
        
        # Update origin to point to user's fork
        git remote set-url origin "$fork_url.git" 2>/dev/null || \
        git remote set-url origin "https://github.com/$(gh api user --jq .login)/$name.git"
        
        echo "🔧 Updated origin remote to point to your fork"
        return 0
    else
        echo "⚠️ Failed to create/find fork"
        return 1
    fi
}

# Update webroot submodule reference to point to user's fork
update_webroot_submodule_reference() {
    local name="$1"
    local commit_hash="$2"
    
    # Get current user login
    local user_login=$(gh api user --jq .login 2>/dev/null || echo "")
    if [ -z "$user_login" ]; then
        echo "⚠️ Could not determine GitHub username"
        return 1
    fi
    
    echo "🔄 Updating webroot submodule reference..."
    cd $(git rev-parse --show-toplevel)
    
    # Update .gitmodules to point to user's fork
    git config -f .gitmodules submodule.$name.url "https://github.com/$user_login/$name.git"
    
    # Sync the submodule URL change
    git submodule sync "$name"
    
    # Update submodule to point to the specific commit
    cd "$name"
    git checkout "$commit_hash" 2>/dev/null
    cd ..
    
    # Commit the submodule reference update
    if [ -n "$(git status --porcelain | grep -E "($name|\.gitmodules)")" ]; then
        git add "$name" .gitmodules
        git commit -m "Update $name submodule to point to $user_login fork (commit $commit_hash)"
        
        if git push origin main 2>/dev/null; then
            echo "✅ Updated webroot submodule reference to your fork"
        else
            echo "⚠️ Failed to push webroot submodule reference update"
        fi
    fi
}

# Fix detached HEAD state by merging into main branch
fix_detached_head() {
    local name="$1"
    
    # Check if we're in detached HEAD state
    local current_branch=$(git symbolic-ref -q HEAD 2>/dev/null || echo "")
    if [ -z "$current_branch" ]; then
        echo "⚠️ $name is in detached HEAD state - fixing..."
        
        # Get the current commit hash
        local detached_commit=$(git rev-parse HEAD)
        
        # Switch to main branch
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || {
            echo "⚠️ No main/master branch found in $name"
            return 1
        }
        
        # Check if we need to merge the detached commit
        if ! git merge-base --is-ancestor "$detached_commit" HEAD; then
            echo "🔄 Merging detached commit $detached_commit into main branch"
            if git merge "$detached_commit" --no-edit 2>/dev/null; then
                echo "✅ Successfully merged detached HEAD in $name"
            else
                echo "⚠️ Merge conflicts in $name - manual resolution needed"
                return 1
            fi
        else
            echo "✅ Detached commit already in $name main branch"
        fi
    fi
    return 0
}

# Enhanced commit and push with automatic fork creation
commit_push() {
    local name="$1"
    local skip_pr="$2"
    
    # Fix detached HEAD before committing
    fix_detached_head "$name"
    
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "Update $name"
        local commit_hash=$(git rev-parse HEAD)
        
        # Determine target branch
        local target_branch="main"
        if [[ "$name" == "useeio.js" ]]; then
            target_branch="dev"
        fi
        
        # Try to push directly first
        if git push origin HEAD:$target_branch 2>/dev/null; then
            echo "✅ Successfully pushed $name to $target_branch branch"
            return 0
        fi
        
        # If direct push fails, check if it's a permission issue
        local push_output=$(git push origin HEAD:$target_branch 2>&1)
        if [[ "$push_output" == *"Permission denied"* ]] || [[ "$push_output" == *"403"* ]]; then
            echo "🔒 Permission denied - setting up fork workflow..."
            
            # Detect parent account
            local parent_account=$(get_parent_account "$name")
            echo "📍 Detected parent: $parent_account/$name"
            
            # Setup fork and update remote
            if setup_fork "$name" "$parent_account"; then
                # Try pushing to fork
                if git push origin HEAD:$target_branch 2>/dev/null; then
                    echo "✅ Successfully pushed $name to your fork"
                    
                    # Create PR if not skipped
                    if [[ "$skip_pr" != "nopr" ]]; then
                        echo "📝 Creating pull request..."
                        local pr_url=$(gh pr create \
                            --title "Update $name" \
                            --body "Automated update from git.sh commit workflow" \
                            --base $target_branch \
                            --head $target_branch \
                            --repo "$parent_account/$name" 2>/dev/null || echo "")
                        
                        if [ -n "$pr_url" ]; then
                            echo "🔄 Created PR: $pr_url"
                        else
                            echo "⚠️ PR creation failed for $name"
                        fi
                    fi
                    
                    # Update webroot submodule reference if this is a submodule
                    if [[ "$name" != "webroot" ]] && [[ "$name" != "exiobase" ]] && [[ "$name" != "profile" ]] && [[ "$name" != "useeio.js" ]] && [[ "$name" != "io" ]]; then
                        update_webroot_submodule_reference "$name" "$commit_hash"
                    fi
                    
                else
                    echo "⚠️ Failed to push to fork"
                fi
            fi
        elif [[ "$skip_pr" != "nopr" ]]; then
            # Other push failure - try feature branch PR
            git push origin HEAD:feature-$name-updates 2>/dev/null && \
            gh pr create --title "Update $name" --body "Automated update" --base $target_branch --head feature-$name-updates 2>/dev/null || \
            echo "🔄 PR creation failed for $name"
        fi
    fi
}

# Update command - streamlined update workflow  
update_command() {
    echo "🔄 Starting update workflow..."
    cd $(git rev-parse --show-toplevel)
    check_webroot
    
    # Update webroot
    echo "📥 Updating webroot..."
    git pull origin main 2>/dev/null || echo "⚠️ Pull conflicts in webroot"
    
    # Update webroot from parent (skip partnertools)
    WEBROOT_REMOTE=$(git remote get-url origin)
    if [[ "$WEBROOT_REMOTE" != *"partnertools"* ]]; then
        add_upstream "webroot" "true"
        merge_upstream "webroot"
    fi
    
    # Update submodules
    echo "📥 Updating submodules..."
    for sub in cloud comparison feed home localsite products projects realitystream swiper team; do
        [ ! -d "$sub" ] && continue
        cd "$sub"
        
        REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$REMOTE" != *"partnertools"* ]]; then
            if [[ "$sub" == "localsite" ]] || [[ "$sub" == "home" ]]; then
                add_upstream "$sub" "true"
            else
                add_upstream "$sub" "false" 
            fi
            merge_upstream "$sub"
        fi
        cd ..
    done
    
    # Update submodule references
    echo "🔄 Updating submodule references..."
    git submodule update --remote --recursive
    
    # Check for and fix any detached HEAD states after updates
    echo "🔍 Checking for detached HEAD states after update..."
    fix_all_detached_heads
    
    # Update trade repos
    echo "📥 Updating trade repos..."
    for repo in exiobase profile useeio.js io; do
        [ ! -d "$repo" ] && continue
        cd "$repo"
        git pull origin main 2>/dev/null || echo "⚠️ Pull conflicts in $repo"
        
        REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$REMOTE" != *"partnertools"* ]]; then
            add_upstream "$repo" "false"
            merge_upstream "$repo"
        fi
        cd ..
    done
    
    echo "✅ Update completed! Use: ./git.sh commit"
}

# Check and fix detached HEAD states in all repositories
fix_all_detached_heads() {
    echo "🔍 Checking for detached HEAD states in all repositories..."
    cd $(git rev-parse --show-toplevel)
    check_webroot
    
    local fixed_count=0
    
    # Check webroot
    echo "📁 Checking webroot..."
    if fix_detached_head "webroot"; then
        ((fixed_count++))
    fi
    
    # Check all submodules
    echo "📁 Checking submodules..."
    for sub in cloud comparison feed home localsite products projects realitystream swiper team; do
        if [ -d "$sub" ]; then
            echo "📁 Checking $sub..."
            cd "$sub"
            if fix_detached_head "$sub"; then
                ((fixed_count++))
            fi
            cd ..
        fi
    done
    
    # Check trade repos
    echo "📁 Checking trade repos..."
    for repo in exiobase profile useeio.js io; do
        if [ -d "$repo" ]; then
            echo "📁 Checking $repo..."
            cd "$repo"
            if fix_detached_head "$repo"; then
                ((fixed_count++))
            fi
            cd ..
        fi
    done
    
    if [ $fixed_count -gt 0 ]; then
        echo "✅ Fixed detached HEAD states in $fixed_count repositories"
        echo "💡 You may want to run './git.sh commit' to update submodule references"
    else
        echo "✅ No detached HEAD states found"
    fi
}

# Create PR for webroot to its parent
create_webroot_pr() {
    local skip_pr="$1"
    
    if [[ "$skip_pr" == "nopr" ]]; then
        return 0
    fi
    
    # Get webroot remote URLs
    local origin_url=$(git remote get-url origin 2>/dev/null || echo "")
    local upstream_url=$(git remote get-url upstream 2>/dev/null || echo "")
    
    # Extract parent account from upstream or determine from origin
    local parent_account=""
    if [[ "$upstream_url" == *"ModelEarth/webroot"* ]]; then
        parent_account="ModelEarth"
    elif [[ "$upstream_url" == *"partnertools/webroot"* ]]; then
        parent_account="partnertools"
    elif [[ "$origin_url" != *"ModelEarth/webroot"* ]] && [[ "$origin_url" != *"partnertools/webroot"* ]]; then
        # This is likely a fork, default to ModelEarth as parent
        parent_account="ModelEarth"
    else
        # Already pointing to parent, no PR needed
        return 0
    fi
    
    echo "📝 Creating webroot PR to $parent_account/webroot..."
    
    # Get current user login for head specification
    local user_login=$(gh api user --jq .login 2>/dev/null || echo "")
    local head_spec="main"
    if [ -n "$user_login" ]; then
        head_spec="$user_login:main"
    fi
    
    local pr_url=$(gh pr create \
        --title "Update webroot with submodule changes" \
        --body "Automated webroot update from git.sh commit workflow - includes submodule reference updates and configuration changes" \
        --base main \
        --head "$head_spec" \
        --repo "$parent_account/webroot" 2>/dev/null || echo "")
    
    if [ -n "$pr_url" ]; then
        echo "🔄 Created webroot PR: $pr_url"
    else
        echo "⚠️ Webroot PR creation failed or not needed"
    fi
}

# Commit specific submodule
commit_submodule() {
    local name="$1"
    local skip_pr="$2"
    
    cd $(git rev-parse --show-toplevel)
    check_webroot
    
    if [ -d "$name" ]; then
        cd "$name"
        commit_push "$name" "$skip_pr"
        
        # Update webroot submodule reference
        cd ..
        git submodule update --remote "$name"
        if [ -n "$(git status --porcelain | grep $name)" ]; then
            git add "$name"
            git commit -m "Update $name submodule reference"
            
            # Try to push webroot changes
            if git push 2>/dev/null; then
                echo "✅ Updated $name submodule reference"
            else
                echo "🔄 Webroot push failed for $name - attempting PR workflow"
                create_webroot_pr "$skip_pr"
            fi
        fi
        
        # Check if we need to create a webroot PR (for when webroot push succeeded but we want PR anyway)
        local webroot_commits_ahead=$(git rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")
        if [[ "$webroot_commits_ahead" -gt "0" ]] && [[ "$skip_pr" != "nopr" ]]; then
            create_webroot_pr "$skip_pr"
        fi
    else
        echo "⚠️ Repository not found: $name"
    fi
}

# Commit all submodules
commit_submodules() {
    local skip_pr="$1"
    
    cd $(git rev-parse --show-toplevel)
    check_webroot
    
    # Commit each submodule with changes
    for sub in cloud comparison feed home localsite products projects realitystream swiper team; do
        [ ! -d "$sub" ] && continue
        cd "$sub"
        commit_push "$sub" "$skip_pr"
        cd ..
    done
    
    # Update webroot submodule references
    git submodule update --remote
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "Update submodule references"
        git push 2>/dev/null || echo "🔄 Webroot push failed"
        echo "✅ Updated submodule references"
    fi
}

# Complete commit workflow
commit_all() {
    local skip_pr="$1"
    
    cd $(git rev-parse --show-toplevel)
    check_webroot
    
    # Commit webroot changes
    commit_push "webroot" "$skip_pr"
    
    # Check if webroot needs PR after direct changes
    local webroot_commits_ahead=$(git rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")
    if [[ "$webroot_commits_ahead" -gt "0" ]] && [[ "$skip_pr" != "nopr" ]]; then
        create_webroot_pr "$skip_pr"
    fi
    
    # Commit all submodules
    commit_submodules "$skip_pr"
    
    # Commit trade repos
    for repo in exiobase profile useeio.js io; do
        [ ! -d "$repo" ] && continue
        cd "$repo"
        commit_push "$repo" "$skip_pr"
        cd ..
    done
    
    echo "✅ Complete commit finished!"
}

# Main command dispatcher
case "$1" in
    "update")
        update_command
        ;;
    "commit")
        if [ "$2" = "submodules" ]; then
            commit_submodules "$3"
        elif [ -n "$2" ]; then
            commit_submodule "$2" "$3"
        else
            commit_all "$2"
        fi
        ;;
    "fix-heads"|"fix")
        fix_all_detached_heads
        ;;
    *)
        echo "Usage: ./git.sh [update|commit|fix] [submodule_name|submodules] [nopr]"
        echo ""
        echo "Commands:"
        echo "  ./git.sh update                    - Run comprehensive update workflow"
        echo "  ./git.sh commit                    - Commit webroot, all submodules, and trade repos"
        echo "  ./git.sh commit [name]             - Commit specific submodule"
        echo "  ./git.sh commit submodules         - Commit all submodules only"
        echo "  ./git.sh fix                       - Check and fix detached HEAD states in all repos"
        echo ""
        echo "Options:"
        echo "  nopr                               - Skip PR creation on push failures"
        exit 1
        ;;
esac

# Always return to webroot repository root at the end. Webroot may have different names for each user who forks and clones it.
cd $(git rev-parse --show-toplevel)