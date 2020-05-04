# Env Status Info

echo " "
tput setaf 2
if [[ ! -n "$PS_APP_VER" ]]; then
  echo "Environment is now setup for WebLogic"
else
  echo "Environment is now setup for $PS_APP_VER"
fi
tput sgr0
echo "   PS_HOME      = $PS_HOME"
echo "   PS_APP_HOME  = $PS_APP_HOME"
echo "   PS_CUST_HOME = $PS_CUST_HOME"
echo "   PS_CFG_HOME  = $PS_CFG_HOME"
echo "   PS_BATCH_HOME= $PS_BATCH_HOME"
echo "   WL_HOME      = $WL_HOME"
echo "   TUXDIR       = $TUXDIR"
echo "   COBOL DIR    = $COBDIR"
echo "   JAVA_HOME    = $JAVA_HOME ($JAVA_VERSION)"
echo "   ORACLE_HOME  = $ORACLE_HOME"
echo "   ORACLE_SID   = $ORACLE_SID"
echo "   TNS_ADMIN    = $TNS_ADMIN"
echo " "
