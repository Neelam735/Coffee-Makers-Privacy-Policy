<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="CreateBankAccount" select="()"/>
   <!-- vBankAccountStatus: NOT_REQUESTED | CREATED | FAILED (set in BankAccountScope) -->
   <xsl:param name="BankAccountStatus" select="'NOT_REQUESTED'"/>
   <xsl:param name="BankFaultMessage" select="''"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <xsl:variable name="bankFailed" select="$BankAccountStatus = 'FAILED'"/>
      <src:SupplierOnboardingResponse>
         <src:requestId><xsl:value-of select="$req/src:requestId"/></src:requestId>
         <src:status><xsl:value-of select="if ($bankFailed) then 'PARTIALLY_CREATED' else 'CREATED'"/></src:status>
         <src:supplierId><xsl:value-of select="$CreateSupplier/erp:Supplier/erp:SupplierId"/></src:supplierId>
         <src:supplierNumber><xsl:value-of select="$CreateSupplier/erp:Supplier/erp:SupplierNumber"/></src:supplierNumber>
         <src:bankAccountStatus><xsl:value-of select="$BankAccountStatus"/></src:bankAccountStatus>
         <xsl:if test="$BankAccountStatus = 'CREATED'"><src:bankAccountId><xsl:value-of select="$CreateBankAccount/erp:ExternalBankAccount/erp:BankAccountId"/></src:bankAccountId></xsl:if>
         <src:message>
            <xsl:choose>
               <xsl:when test="$bankFailed"><xsl:value-of select="concat('Supplier, address, site and contacts created, but the bank account could not be created: ', $BankFaultMessage)"/></xsl:when>
               <xsl:when test="$BankAccountStatus = 'CREATED'">Supplier, address, site, contacts and bank account created in Oracle ERP Cloud.</xsl:when>
               <xsl:otherwise>Supplier, address, site and contacts created in Oracle ERP Cloud.</xsl:otherwise>
            </xsl:choose>
         </src:message>
      </src:SupplierOnboardingResponse>
   </xsl:template>
</xsl:stylesheet>
