#!/bin/bash

# --- 1. CONFIGURATION ---
# Application and Namespace details in Konflux
APP_NAME="iib-builder-qe"
NAMESPACE="iib-tenant"

# Source code location (GitLab)
GITLAB_URL=""
GIT_PROVIDER_URL=""

# Naming suffix for environment separation
ENV_SUFFIX="qe"

# --- REPOSITORY PATH LOGIC (Critical for Pipelines-as-Code) ---
# We strip the protocol, the host, and the '.git' suffix.
# Correct format for the annotation MUST be "org/repo" (e.g., exd-guild-hello-operator-gitlab/iib-api-test-index-configs).
GIT_HOST=$(echo "$GIT_PROVIDER_URL" | sed -e 's|https://||' -e 's|http://||')
REPO_PATH=$(echo "$GITLAB_URL" | sed -e 's|https://||' -e "s|$GIT_HOST/||" -e 's|.git$||')
REPO_NAME=$(basename "$GITLAB_URL" .git)

# Validate that the GitLab Token is available in the environment
if [ -z "$GITLAB_TOKEN" ]; then
    echo "❌ ERROR: GITLAB_TOKEN is not set. Run: export GITLAB_TOKEN=your_token"
    exit 1
fi

echo "----------------------------------------------------"
echo "🚀 Starting Konflux Onboarding: $APP_NAME"
echo "🔍 Debug Path Check:"
echo "   Host: $GIT_HOST"
echo "   Repo Path: $REPO_PATH"
echo "----------------------------------------------------"

# --- 2. REPOSITORY-SPECIFIC SCM SECRET ---
# Creates a secret used by Pipelines-as-Code (PaC) to access GitLab.
# It uses specific labels and annotations so PaC can match this secret to the specific repository.
echo "🔐 Creating SCM Secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "pac-secret-${REPO_NAME}"
  namespace: "${NAMESPACE}"
  labels:
    # Essential label for Konflux to recognize this as an SCM credential
    appstudio.redhat.com/credentials: scm
    # Links the secret to the specific GitLab domain
    appstudio.redhat.com/scm.host: "${GIT_HOST}"
  annotations:
    # The most important part: matches the secret to the specific repo path
    appstudio.redhat.com/scm.repository: "${REPO_PATH}"
type: kubernetes.io/basic-auth
stringData:
  # The GitLab Personal Access Token (PAT)
  password: "${GITLAB_TOKEN}"
EOF

# --- 3. DYNAMIC BRANCH DISCOVERY ---
# Automatically fetches all remote branches to create a Component for each one.
echo "🔍 Discovering remote branches..."
BRANCHES=($(git ls-remote --heads "$GITLAB_URL" | awk '{print $2}' | sed 's/refs\/heads\///' | grep -v 'HEAD'))

if [ ${#BRANCHES[@]} -eq 0 ]; then
    echo "❌ ERROR: No branches found. Check access to $GITLAB_URL"
    exit 1
fi

# --- 4. COMPONENT LOOP ---
# Iterates through every discovered branch to set up the build infrastructure.
for BRANCH in "${BRANCHES[@]}"; do
    # Sanitize branch name for Kubernetes resource naming (v4.11 -> v4-11)
    BRANCH_SAFE="${BRANCH//./-}"
    K8S_SAFE_NAME="iib-${ENV_SUFFIX}-${REPO_NAME}-${BRANCH_SAFE}"

    # Ensure the name does not exceed the Kubernetes 63-character limit
    [ ${#K8S_SAFE_NAME} -gt 63 ] && K8S_SAFE_NAME="iib-${ENV_SUFFIX}-${REPO_NAME:0:20}-${BRANCH_SAFE}"

    echo "----------------------------------------------------"
    echo "📦 Processing: $K8S_SAFE_NAME (Branch: $BRANCH)"

    # A. Create ImageRepository
    # Requests Konflux to create a private repository in Quay.io for the build output.
    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: ImageRepository
metadata:
  name: $K8S_SAFE_NAME
  namespace: $NAMESPACE
  labels:
    appstudio.redhat.com/application: $APP_NAME
    appstudio.redhat.com/component: $K8S_SAFE_NAME
spec:
  image:
    name: $NAMESPACE/$K8S_SAFE_NAME
    visibility: private
EOF

    # B. Create Component
    # Defines the build source. If it's the 'main' branch, we request a Merge Request (PaC onboarding).
    REQUEST_TYPE="configure-pac-no-mr"
    [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]] && REQUEST_TYPE="configure-pac"

    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: $K8S_SAFE_NAME
  namespace: $NAMESPACE
  labels:
    appstudio.redhat.com/application: $APP_NAME
    appstudio.redhat.com/component: $K8S_SAFE_NAME
  annotations:
    build.appstudio.openshift.io/request: $REQUEST_TYPE
    git-provider: gitlab
    git-provider-url: $GIT_PROVIDER_URL
    pipelinesascode.tekton.dev/repository-name: "$K8S_SAFE_NAME"
spec:
  application: $APP_NAME
  componentName: $K8S_SAFE_NAME
  source:
    git:
      url: $GITLAB_URL
      revision: $BRANCH
      context: ./
      dockerfileUrl: index.Dockerfile
EOF

    # C. ACTIVE POLLING AND PATCHING (Anti-Race Condition Logic)
    # We wait for the Image Controller to generate the Quay URL.
    # Once found, we manually patch the Component to trigger the Build Service immediately.
    echo "⏳ Waiting for Image Controller to assign URL..."
    FOUND_URL=""
    for i in {1..20}; do
        # Check if the URL is already present in the ImageRepository status
        FOUND_URL=$(kubectl get imagerepository "$K8S_SAFE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.image.url}' 2>/dev/null)
        if [ -n "$FOUND_URL" ]; then break; fi
        echo -n "."
        sleep 3
    done

    if [ -n "$FOUND_URL" ]; then
        echo -e "\n✅ URL detected. Patching component to unblock Build Service..."
        # Manually injecting the URL into the component spec to bypass controller delays
        kubectl patch component "$K8S_SAFE_NAME" -n "$NAMESPACE" --type='merge' -p "{\"spec\":{\"containerImage\":\"$FOUND_URL\"}}"
    else
        echo -e "\n⚠️  Timeout: Controller is slow. Build Service might be delayed."
    fi
done

echo "----------------------------------------------------"
echo "✅ SUCCESS: Onboarding finished."
echo "----------------------------------------------------"
echo "🧹 CLEANUP COMMANDS:"
echo ""
echo "1. Delete all Components:"
echo "   kubectl delete components -n $NAMESPACE -l appstudio.redhat.com/application=$APP_NAME"
echo ""
echo "2. Delete all Image Repositories:"
echo "   kubectl delete imagerepositories -n $NAMESPACE -l appstudio.redhat.com/application=$APP_NAME"
echo ""
echo "3. Delete SCM Secret:"
echo "   kubectl delete secret pac-secret-${REPO_NAME} -n $NAMESPACE"
echo ""
echo "4. Delete Repository objects (PaC):"
echo "   kubectl delete repositories.pipelinesascode.tekton.dev -n $NAMESPACE -l appstudio.redhat.com/application=$APP_NAME"
echo "----------------------------------------------------"